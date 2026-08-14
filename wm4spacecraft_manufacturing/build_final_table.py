#!/usr/bin/env python3
"""
build_final_table.py -- 5시간 4정책 스윕(run_4pol.sh)의 결과를 오프라인으로 조립해 최종
비교표(artifacts_4pol/FINAL.md)를 만든다.

★ 이 스크립트는 새 시뮬을 절대 돌리지 않는다. julia 를 호출하지 않고, `llm_ood_eval.py run`
   도 호출하지 않는다(둘 다 돌고 있는 스윕을 깨뜨린다 -- README 함정 30). 여기서 실행하는
   서브프로세스는 `llm_ood_eval.py report`(순수 파이썬, jsonl 위 집계) 와 `shadow_score.py`
   (순수 파이썬, 새 시뮬 0회) 뿐이다.

★ 지표 수학은 재구현하지 않는다. `llm_ood_eval.py report --json/--md` 와 `shadow_score.py --md`
   가 이미 계산한 것을 셸아웃으로 얻어 그대로 읽는다 -- 중복 구현은 문서와 아티팩트가 조용히
   갈라지는 원인이다.

★ `oracle` 행은 실행 가능한 온라인 정책이 아니다(`tools/monitor/policy.jl` 에 oracle 분기 없음).
   표에서는 네 번째 주자가 아니라 천장(ceiling)/원점(origin-of-scale) 이다 -- 그렇게 명시하지
   않으면 "oracle 1등"이라는 공허한 주장이 나온다(정의상 항상 참이라 정보가 없다).

★ 결측은 절대 0 도 빈칸도 아니다. `미측정 (STEP D 필요)` 로 명시한다. 실패/스킵된 case 도
   조용히 빠지지 않고 이름으로 남는다(silent truncation 금지).

실행
----
  python build_final_table.py [--results-dir results_4pol] [--out-dir artifacts_4pol]

테스트(픽스처, 라이브 스윕과 무관):
  mkdir -p /tmp/ft/results_4pol
  cp results/llm_ood_eval.jsonl /tmp/ft/results_4pol/all.jsonl
  python build_final_table.py --results-dir /tmp/ft/results_4pol --out-dir /tmp/ft/artifacts_4pol
"""
import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import reference_policy  # noqa: E402  (BASIS 문자열만 읽는다 -- 채점 로직은 쓰지 않는다)
from stats_paired import paired_wilcoxon, pair_boards, holm, sign_test   # noqa: E402

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

# 스윕 순서 그대로(run_4pol.sh CASES 와 동일) -- plan §5-a Tier1->Tier2->Tier3.
CASES = ["battery", "fault", "zonecore", "all", "fault_battery", "fault_zone", "battery_zone", "zone"]

# 최종표 행 순서: oracle(천장) -> surrogate -> noop -> llm(dspy). plan §8 그대로.
ROW_ORDER = [("oracle", None), ("surrogate", "surrogate"), ("noop", "noop"), ("llm", "dspy")]

def limitations_lines(boards_by_case):
    """§7 한계. 표본 크기 주장은 전부 실제 boards 에서 계산한다 -- 리터럴 금지.

    (2026-08-11) 예전에는 시드 수와 부호검정 하한이 문자열 리터럴이었고, 같은 문장이
    build_final_table.py 와 build_md_report.py **양쪽에** 복사돼 있었다. 시드를 20개로
    늘려 재생성하면 표는 n=20, 산문은 옛 표본크기인 자가당착 문서가 나온다. 그 결함을 여기서 막는다.

    주의: 이 파일은 test_report_sample_size.py 가 소스를 직접 grep 한다. 주석·독스트링에도
    옛 표본크기 문구를 그대로 적지 말 것 -- 적으면 그 회귀 테스트가 실패한다.
    """
    # 데이터 없는 case(boards=[])는 건너뛴다 -- 안 그러면 min() 이 0 으로 무너져 "시드 0개, 최소
    # p=1.000" 이 나온다(fix round 2, 2026-08-11 코드리뷰 지적). 20시드 스윕이 zonecore 를 일부러
    # 빼므로(zone 의 증명된 중복) 이건 실제로 벌어질 입력이다 -- 방어를 호출부 하나에만 두지 않는다.
    n_seeds_by_case = {c: len({b.get("ood_seed") for b in bs}) for c, bs in boards_by_case.items() if bs}
    n_seeds = min(n_seeds_by_case.values()) if n_seeds_by_case else 0
    # 부호검정 하한: 무승부가 없고 전승/전패일 때의 양측 p = 2 * 0.5^n
    floor_p = 2.0 * (0.5 ** n_seeds) if n_seeds > 0 else 1.0
    floor_str = ("%.3f" % floor_p) if floor_p >= 1e-3 else ("%.1e" % floor_p)

    world_seeds = sorted({b.get("world_seed") for bs in boards_by_case.values()
                          for b in bs if b.get("world_seed") is not None})
    ws = world_seeds[0] if len(world_seeds) == 1 else world_seeds

    items = []
    if n_seeds < 6:
        items.append("통계적 유의성 없음 -- 시드 %d개, 부호검정(sign test) 최소 p=%s "
                     "(짝이 6개 미만이면 양측 p 가 0.05 아래로 내려갈 수 없다)." % (n_seeds, floor_str))
    else:
        items.append("시드 %d개 -- 부호검정 최소 양측 p=%s. 무승부는 검정에서 제외되므로 "
                     "천장효과(모든 정책이 항상 완주)인 case 에서는 시드를 늘려도 "
                     "유의해지지 않는다." % (n_seeds, floor_str))
    items.append("`world_seed` 고정(=%s) -- 다른 공장 배치(레이아웃)에 대한 일반화는 이번에 재지 않는다." % ws)
    items.append("빌드 시간(E4)은 **완주판만** 재므로 선택편향이 있다 -- 완주한 판끼리만 비교하는 것이라, "
                 "완주율이 낮은 정책일수록 살아남은 판만 뽑혀 유리하게 보인다.")
    items.append("shadow 채점은 **상태조건부 결정 충실도**다(\"이 상태에서 이 정책이 a\\* 를 골랐겠는가\"). "
                 "결과 비교가 아니다 -- shadow 숫자로 완주율/시간/에너지 주장을 하면 안 된다.")
    if "zonecore" in boards_by_case and "zone" in boards_by_case:
        items.append("`zone` 과 `zonecore` 는 같은 실험이다 -- `run_demo.jl:433` 이 "
                     "`DEMO_OOD_STREAM3=1` 에서 `:zonecore` 를 `:zone` 으로 바꾼다.")
    return ["## 7. 한계", ""] + ["- %s" % it for it in items] + [""]


def repro_lines(n_boards, seeds, cases):
    """재현 절차. 판 수·시드·case 목록을 전부 인자에서 받는다 -- 리터럴 금지."""
    seed_str = ",".join(str(s) for s in seeds)
    case_str = ",".join(cases)
    return [
        "재현 절차:", "",
        "```bash",
        "# 1) %d 판 스윕 (순차, julia 를 내부에서 부른다 -- 다른 julia 와 동시에 돌리지 말 것)" % n_boards,
        "bash run_4pol.sh --deadline-seconds 43200 --seeds %s --cases %s" % (seed_str, case_str),
        "",
        "# 2) 오라클 라벨(fault/zone 축) 재생성 -- julia, 순차 (README 함정 30)",
        "bash run_step_d_all.sh",
        "",
        "# 3) 스윕 산출물을 case별 report/shadow md+json 으로 조립 (순수 파이썬)",
        "python build_final_table.py --results-dir results_4pol --out-dir artifacts_4pol",
        "",
        "# 4) 이 문서 (순수 파이썬, julia 호출 없음, subprocess 없음)",
        "python build_md_report.py --results-dir results_4pol --out-dir artifacts_4pol --oracle-dir oracle/out",
        "```", "",
    ]

MISSING_TOKEN = "미측정 (STEP D 필요)"
# combined-kind case(all/fault_battery/fault_zone/battery_zone)는 단일-종류 오라클 격자가 애초에
# 존재하지 않는다(사건이 섞여서 나온다) -- MISSING_TOKEN 과는 다른 사실이다. MISSING_TOKEN 은
# "라벨이 아직 없다, STEP D 를 돌리면 채워진다"는 뜻이라 여기 쓰면 독자에게 끝난 ~2시간짜리 STEP D
# 를 다시 돌리라고 잘못 지시하게 된다(FIX ROUND 1 리뷰 발견 사항). 절대 채워지지 않는다는 것을
# 구분해서 말하는 별도 토큰.
NA_MIXED_KIND_TOKEN = "N/A (혼합종류 case -- 단일축 오라클 격자 없음)"
DASH = "—"  # —


# =====================================================================================
# 0. 유틸
# =====================================================================================
def load_jsonl_lenient(path: Path):
    """줄 단위 json 로더. 파싱 안 되는 줄(스윕이 지금 쓰고 있어 잘린 마지막 줄 등)은 세되
    크래시하지 않는다. (rows, n_bad_lines) 를 돌려준다."""
    rows, n_bad = [], 0
    if not path.exists():
        return rows, n_bad
    text = path.read_text(encoding="utf-8", errors="replace")
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            n_bad += 1
    return rows, n_bad


def dedup_boards(rows):
    """(ood_seed, policy) 별 마지막 것만 -- 재실행/재개는 덮어쓰기다(llm_ood_eval.load_rows 와
    같은 규칙). 이 case 파일 하나 안에서만 적용하므로 case 키는 빼도 안전하다."""
    d = {}
    for r in rows:
        d[(r.get("ood_seed"), r.get("policy"))] = r
    return list(d.values())


def run_tool(cmd, timeout=300):
    try:
        proc = subprocess.run(cmd, cwd=str(HERE), capture_output=True, text=True, timeout=timeout)
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired as e:
        return 124, (e.stdout or ""), "TIMEOUT after %ss running: %s" % (timeout, " ".join(cmd))
    except Exception as e:  # noqa: BLE001 -- 어시블러는 절대 죽지 않는다, 사유를 적고 계속한다
        return 1, "", "EXCEPTION launching %s: %r" % (" ".join(cmd), e)


def resolve_path(p):
    pp = Path(p)
    return pp if pp.is_absolute() else (HERE / pp)


def fmt_pct(rate, num=None, den=None):
    if rate is None:
        return DASH
    if num is not None and den is not None:
        return "%.0f%% (%d/%d)" % (100 * rate, num, den)
    return "%.0f%%" % (100 * rate)


def fmt_time(mean, sd):
    if mean is None:
        return DASH
    return "%.1f ± %.1f s" % (mean, sd if sd is not None else 0.0)


def fmt_num(x, nd=1):
    if x is None:
        return DASH
    return "%.*f" % (nd, x)


# =====================================================================================
# 0b. 짝지은 통계 (E1 부호검정 / E3·E4 Wilcoxon) + Holm 보정 (task 6, 20시드 검증)
# =====================================================================================
PAIRS = [("noop", "surrogate"), ("noop", "dspy"), ("surrogate", "dspy")]


def _energy(r):
    return ((r or {}).get("battery") or {}).get("energy_per_closed")


def _time_if_complete(r):
    """E4 는 완주판만 잰다 -- 완주하지 않은 판은 None(짝에서 탈락). 이게 곧 선택편향의 출처다."""
    return r.get("sim_seconds") if r.get("complete") else None


def paired_tests(rows):
    """case 하나의 판들에 대해 3개 정책쌍 x E1/E3/E4 검정. 반환 {"a__b": {...}}."""
    out = {}
    for a, b in PAIRS:
        ca, cb = pair_boards(rows, a, b, "complete")
        w = sum(1 for x, y in zip(ca, cb) if bool(x) and not bool(y))
        l = sum(1 for x, y in zip(ca, cb) if not bool(x) and bool(y))
        t = sum(1 for x, y in zip(ca, cb) if bool(x) == bool(y))
        e1 = sign_test(w, l)

        ea = [_energy(r) for r in _rows_for(rows, a)]
        eb = [_energy(r) for r in _rows_for(rows, b)]
        e3 = paired_wilcoxon(ea, eb)

        ta = [_time_if_complete(r) for r in _rows_for(rows, a)]
        tb = [_time_if_complete(r) for r in _rows_for(rows, b)]
        e4 = paired_wilcoxon(ta, tb)
        e4_note = e4["note"] or ("완주판 짝 %d개만 비교 -- 선택편향(생존한 판끼리)" % e4["n_used"])

        out["%s__%s" % (a, b)] = {
            "e1_wins": w, "e1_losses": l, "e1_ties": t, "e1_sign_p": e1,
            "e1_note": "천장(전부 동점) -- 시드를 늘려도 유의해질 수 없다" if t and not (w or l) else "",
            "e3_wilcoxon_p": e3["p"], "e3_median_diff": e3["median_diff"], "e3_n": e3["n_used"],
            "e3_note": e3["note"],
            "e4_wilcoxon_p": e4["p"], "e4_median_diff": e4["median_diff"], "e4_n": e4["n_used"],
            "e4_note": e4_note,
        }
    return out


def _rows_for(rows, policy):
    """정책 하나의 판을 ood_seed 순으로. 짝맞춤은 pair_boards 와 같은 규칙(빠진 시드는 None)."""
    idx = {(r.get("ood_seed"), r.get("policy")): r for r in rows}
    seeds = sorted({r.get("ood_seed") for r in rows if r.get("ood_seed") is not None})
    return [idx.get((s, policy)) or {} for s in seeds]


def holm_family(pmap):
    """{"case__a__b": p} -> 같은 딕셔너리 모양의 Holm 조정 p. 족(family) 안에서만 조정한다."""
    keys = sorted(pmap)
    adj = holm([pmap[k] for k in keys])
    return dict(zip(keys, adj))


def apply_holm_correction(all_artifacts, out_dir: Path):
    """모든 case 의 paired_tests 가 다 모인 뒤(2-pass 의 2단계)에만 부를 것 -- Holm 은 case 하나가
    아니라 endpoint 족(7 case x 3 정책쌍 = 21 검정) 전체에 적용된다. E1/E3/E4 는 서로 다른 물음이라
    **족을 절대 섞지 않는다**(endpoint 별로 따로 21개씩 보정). 조정된 값을 모든 case JSON에 같은
    딕셔너리로 써 넣고(어느 case 를 읽어도 전체 족을 볼 수 있게), 디스크의 `<case>.json` 도 갱신한다
    (report --json 이 이미 써 놓은 것을 파이썬으로 다시 연다 -- llm_ood_eval.py 를 다시 부르지 않는다)."""
    pmap = {"e1": {}, "e3": {}, "e4": {}}
    for case in CASES:
        art = all_artifacts.get(case)
        if not art or not art.get("report_ok"):
            continue
        for pair_key, t in (art["json_data"].get("paired_tests") or {}).items():
            k = "%s__%s" % (case, pair_key)
            pmap["e1"][k] = t["e1_sign_p"]
            pmap["e3"][k] = t["e3_wilcoxon_p"]
            pmap["e4"][k] = t["e4_wilcoxon_p"]
    holm_adjusted = {ep: holm_family(pm) for ep, pm in pmap.items()}

    for case in CASES:
        art = all_artifacts.get(case)
        if not art or not art.get("report_ok"):
            continue
        art["json_data"]["holm_adjusted"] = holm_adjusted
        json_path = art.get("json_path") or (out_dir / ("%s.json" % case))
        json_path.write_text(json.dumps(art["json_data"], ensure_ascii=False, indent=2), encoding="utf-8")
    return holm_adjusted


# =====================================================================================
# 1. case 판정 -- status 파일(마지막 줄이 이긴다) x 실제 파일(있으면 그게 이긴다)
# =====================================================================================
def load_status(night_dir: Path):
    status_path = night_dir / "status_4pol.jsonl"
    recs, n_bad = load_jsonl_lenient(status_path)
    by_case = {}
    for r in recs:  # later lines supersede earlier ones for the same case (append-only log)
        c = r.get("case")
        if c is not None:
            by_case[c] = r
    return by_case, n_bad, status_path


def discover_cases(results_dir: Path, night_dir: Path):
    """8개 case 각각에 대해 판정한다. 파일이 있고 비어있지 않고 파싱 가능한 줄이 1개 이상이면
    '데이터 있음' -- 그 상태 라인이 stale(예: 아직 도는 스윕이 이전에 남긴 all-skipped 블록)해도
    파일이 이긴다."""
    status_by_case, status_n_bad, status_path = load_status(night_dir)
    info = {}
    for case in CASES:
        path = results_dir / ("%s.jsonl" % case)
        rows, n_bad = load_jsonl_lenient(path)
        has_data = len(rows) > 0
        info[case] = dict(
            case=case, path=path, has_data=has_data,
            raw_rows=rows, n_bad_lines=n_bad,
            status=status_by_case.get(case),
        )
    return info, status_by_case, status_n_bad, status_path


# =====================================================================================
# 2. per-case 아티팩트 -- shell out to llm_ood_eval.py report / shadow_score.py
# =====================================================================================
def build_case_artifacts(case_info, out_dir: Path, py: str):
    case = case_info["case"]
    path = case_info["path"]
    result = dict(report_ok=False, report_err=None, json_data=None,
                  shadow_ok=False, shadow_err=None)

    json_path = out_dir / ("%s.json" % case)
    md_path = out_dir / ("%s.md" % case)
    rc, out, err = run_tool([py, str(HERE / "llm_ood_eval.py"), "report",
                              "--out", str(path), "--json", str(json_path), "--md", str(md_path)])
    if rc != 0 or not json_path.exists():
        result["report_err"] = ("llm_ood_eval.py report exit=%d\nstdout(tail)=%s\nstderr(tail)=%s"
                                 % (rc, out[-800:], err[-800:]))
        return result
    try:
        result["json_data"] = json.loads(json_path.read_text(encoding="utf-8"))
        result["report_ok"] = True
        result["md_text"] = md_path.read_text(encoding="utf-8") if md_path.exists() else ""
    except Exception as e:  # noqa: BLE001
        result["report_err"] = "json 파싱 실패 %s: %r" % (json_path, e)
        return result

    # task 6: E1(부호검정)/E3(에너지)/E4(빌드시간) 짝지은 검정 -- case 하나의 3개 정책쌍.
    # dedup 된 raw board 를 그대로 쓴다(json_data["policies"] 는 이미 집계된 요약이라 짝짓기엔 못 쓴다).
    boards = dedup_boards(case_info["raw_rows"])
    result["json_data"]["paired_tests"] = paired_tests(boards)
    result["json_path"] = json_path

    shadow_md = out_dir / ("shadow_%s.md" % case)
    rc2, out2, err2 = run_tool([py, str(HERE / "shadow_score.py"), "--in", str(path), "--md", str(shadow_md)])
    if rc2 != 0:
        result["shadow_err"] = ("shadow_score.py exit=%d\nstdout(tail)=%s\nstderr(tail)=%s"
                                 % (rc2, out2[-500:], err2[-500:]))
    else:
        result["shadow_ok"] = True
        result["shadow_md_path"] = shadow_md
    return result


def build_pooled_shadow(data_case_paths, out_dir: Path, py: str):
    if not data_case_paths:
        return dict(ok=False, err="pooled shadow 건너뜀 -- 데이터 있는 case 파일이 하나도 없다.")
    pooled_md = out_dir / "shadow.md"
    cmd = [py, str(HERE / "shadow_score.py"), "--in"] + [str(p) for p in data_case_paths] + \
          ["--md", str(pooled_md)]
    rc, out, err = run_tool(cmd)
    if rc != 0:
        return dict(ok=False, err="pooled shadow_score.py exit=%d\nstderr(tail)=%s" % (rc, err[-800:]))
    return dict(ok=True, path=pooled_md)


def check_v4(boards):
    """V4 -- 판 수가 (시드 수 x 정책 수) 인지. 기대값을 하드코딩하지 않는다.

    (2026-08-11) 예전에는 15 가 리터럴이었다 -- 20시드로 늘리면 60판이 정상인데도
    "판 수 초과" 로 경고해 정상 스윕을 결함처럼 보이게 만든다.
    """
    n_seeds = len({b.get("ood_seed") for b in boards})
    n_pol = len({b.get("policy") for b in boards})
    expected = n_seeds * n_pol
    n = len(boards)
    if n == expected:
        return ["V4 [PASS] 판 수 %d (%d seeds x %d policies) 그대로." % (n, n_seeds, n_pol)]
    if n < expected:
        return ["V4 [WARN] 판 수 부족: 기대 %d (%d seeds x %d policies), 실제 %d."
                % (expected, n_seeds, n_pol, n)]
    return ["V4 [WARN] 판 수 초과: 기대 %d (%d seeds x %d policies), 실제 %d."
            % (expected, n_seeds, n_pol, n)]


# =====================================================================================
# 3. V1-V4 사후 검증 -- 원본 raw jsonl 의 decisions[] 를 직접 본다(report --json 에는
#    llm/enacted/rule/surrogate 원본 필드가 안 실린다 -- reference_policy.score() 가
#    chosen/reference/correct 로 재구성해 버리기 때문에, 검증엔 raw row 가 필요하다).
# =====================================================================================
def validate_case(case, boards):
    """boards = dedup 된 (ood_seed,policy) 판 목록. (verdict_lines: list[str]) 을 돌려준다."""
    lines = []

    by_policy = {}
    for b in boards:
        by_policy.setdefault(b.get("policy"), []).append(b)

    # ---- V1: llm lane 이 진짜인지 (silent canonical fallback 아닌지) --------------------
    dspy_boards = sorted(by_policy.get("dspy", []), key=lambda r: (r.get("ood_seed") or 0))
    canonical_boards = sorted(by_policy.get("canonical", []), key=lambda r: (r.get("ood_seed") or 0))

    def macro_seq(boards_):
        seq = []
        for r in boards_:
            for d in (r.get("decisions") or []):
                seq.append(d.get("macro"))
        return seq

    dspy_decisions = [d for r in dspy_boards for d in (r.get("decisions") or [])]
    n_dspy_dec = len(dspy_decisions)
    n_enacted_is_dspy = sum(1 for d in dspy_decisions if d.get("enacted") == "dspy")
    n_matches_llm = sum(1 for d in dspy_decisions if d.get("macro") == d.get("llm"))

    if not dspy_boards:
        lines.append("V1 [WARN] dspy 판이 이 case 에 없다 -- LLM lane 검증 대상 없음.")
    elif canonical_boards:
        dspy_seq = macro_seq(dspy_boards)
        can_seq = macro_seq(canonical_boards)
        if dspy_seq and dspy_seq == can_seq:
            lines.append(
                "V1 [FAIL] dspy 와 canonical 의 enacted-macro 시퀀스가 완전히 동일하다"
                "(n=%d) -- 폴백 신호(같은 정책을 두 번 잰 것일 수 있다)." % len(dspy_seq))
        else:
            lines.append(
                "V1 [PASS] dspy(n=%d)/canonical(n=%d) enacted-macro 시퀀스가 다르다 -- 동일 정책 "
                "이중 계측 신호 없음. 참고: dspy 판 중 enacted=='dspy' %d/%d, macro==llm(자기 shadow "
                "선택과 일치) %d/%d." % (len(dspy_seq), len(can_seq), n_enacted_is_dspy, n_dspy_dec,
                                     n_matches_llm, n_dspy_dec))
    else:
        note = ("canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 "
                "상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다.")
        if n_dspy_dec == 0:
            lines.append("V1 [WARN] %s dspy 판은 있으나 결정이 0개라 확인 불가." % note)
        elif n_matches_llm == n_dspy_dec and n_enacted_is_dspy == n_dspy_dec:
            lines.append(
                "V1 [PASS] %s dspy 판이 enacted 한 macro 는 %d/%d 결정 전부 자기 자신의 llm shadow "
                "선택과 일치했고, enacted 태그도 %d/%d 전부 'dspy' -- 폴백(canonical 이 대신 채워짐)"
                " 증거 없음." % (note, n_matches_llm, n_dspy_dec, n_enacted_is_dspy, n_dspy_dec))
        else:
            lines.append(
                "V1 [WARN] %s macro==llm 일치 %d/%d, enacted=='dspy' %d/%d -- 불일치가 있다(폴백 "
                "여부는 canonical 비교 없이는 확정 못 함, 로그로 개별 확인 필요)."
                % (note, n_matches_llm, n_dspy_dec, n_enacted_is_dspy, n_dspy_dec))

    # ---- V2: noop 은 정말 noop 인지 -----------------------------------------------------
    noop_boards = by_policy.get("noop", [])
    if not noop_boards:
        lines.append("V2 [WARN] noop 판이 이 case 에 없다 -- 검증 대상 없음.")
    else:
        offenders = []
        n_dec = 0
        for r in noop_boards:
            for d in (r.get("decisions") or []):
                n_dec += 1
                if d.get("macro") != "NOOP":
                    offenders.append((r.get("ood_seed"), d.get("at"), d.get("macro")))
        if offenders:
            lines.append("V2 [FAIL] noop 판에서 NOOP 이 아닌 macro 가 %d/%d 건 enacted 됐다: %s"
                          % (len(offenders), n_dec,
                             ", ".join("seed=%s@t=%s->%s" % o for o in offenders[:10])))
        else:
            lines.append("V2 [PASS] noop 판의 macro %d건 전부 NOOP." % n_dec)

    # ---- V3: 빈 board 없는지 -------------------------------------------------------------
    empty = [(r.get("policy"), r.get("ood_seed")) for r in boards if len(r.get("decisions") or []) == 0]
    if empty:
        lines.append("V3 [FAIL] n_decisions==0 인 판이 %d개 있다: %s"
                      % (len(empty), ", ".join("%s/seed=%s" % e for e in empty)))
    else:
        lines.append("V3 [PASS] 빈 board(n_decisions==0) 없음 (판 %d개 전부 결정 >=1)." % len(boards))

    # ---- V4: 행 수 (기대값은 실제 시드 수 x 정책 수에서 계산한다 -- 리터럴 금지) ---------------
    lines.extend(check_v4(boards))

    return lines


# =====================================================================================
# 4. FINAL.md 조립
# =====================================================================================
# 2026-08-13 갱신: 이 배너는 오래 "policy.jl 에 oracle 분기 없음(`grep -i oracle` 0건)" 이라고
# 단언했다. 커밋 d318d1d(2026-08-13, oracle 실행 레인 신설)가 그 문장을 **거짓**으로 만들었는데도
# 배너는 그대로 9번 찍혔다. 아래 네 문장이 지금의 사실이다 -- 셋을 구분하지 않으면(레인의 존재 /
# 이 스윕의 참가 여부 / 격자의 존재) 표를 잘못 읽는다.
ORACLE_NOTE = (
    "> **`oracle` 행은 이 스윕이 실행한 판이 아니다 -- 오프라인 라벨 격자에서 유도한 "
    "천장/원점(ceiling)이다.**\n"
    "> \n"
    "> - `oracle` 은 이제 `tools/monitor/policy.jl` 의 **실제로 실행되는 레인**이다"
    "(`oracle_macro()` 가 결정시점에 기준 행동 a* 를 계산하고 `pol[\"oracle\"]` 로 집행한다; "
    "2026-08-13 커밋 `d318d1d` 에서 신설). \"policy.jl 에 oracle 분기가 없다\"는 과거 서술은 "
    "그 커밋 이후로 사실이 아니다.\n"
    "> - **그러나 이 630판 스윕에는 그 레인이 들어 있지 않다.** 이 스윕이 돌린 정책 집합은 "
    "`noop,surrogate,dspy` 셋뿐이다. 따라서 아래 표에 보이는 `oracle` 행의 값은 실행된 판에서 나온 "
    "것이 아니라 **오프라인 라벨 격자**(`reference_policy.py` 의 기준 행동 a*)에서 나온 것이다. "
    "\"옳은 결정 100%\"는 성능 주장이 아니라 나머지 세 행이 이 원점에서 얼마나 떨어졌는지 재는 "
    "눈금이다.\n"
    "> - 조합 case(`fault_battery`/`fault_zone`/`battery_zone`/`all`)의 `oracle` 칸이 `0,0` 으로 "
    "읽힌다면 그것은 \"모든 판이 실패했다\"가 **아니라 \"해당 격자가 아예 없다\"** 는 뜻이다 -- "
    "`results_matrix.py:44` 의 `ORACLE_KIND` 에는 조합 키가 없다(사건이 섞여서 나오므로 단일-종류 "
    "격자가 성립하지 않는다).\n"
    "> - 실행 레인의 ZoneTruth 가지는 `reference_policy.py` 와 **의도적으로 갈린다**: Julia 쪽은 "
    "Python 채점기가 관측할 수 없는 `RECOVERY_SPARES` 상태로 게이트를 건다(요약의 `zone_primitives` "
    "에 그런 칸이 없다). 그래서 `score()` 기준 결정 적중률은 84/84 가 아니라 **80/84** 다. "
    "완주(completion)는 Julia 쪽이 authoritative 이고, 발행되는 `decision_acc` 열은 Python 쪽 "
    "값을 그대로 유지한다."
)


# case(8개 스윕 case) -> build_md_report.compute_ceilings() 의 축 키. combined case(all/
# fault_battery/fault_zone/battery_zone)는 단일-종류 오라클 격자가 없다(사건이 섞여서 나온다) --
# 매핑에 없으면 render_row_cells 가 NA_MIXED_KIND_TOKEN 을 낸다(STEP D 로도 못 채우는, 진짜 결측과는
# 다른 "해당 없음" -- 라벨 파일이 있고 없고와 무관하게 단일축 오라클 격자 자체가 존재하지 않는다).
CASE_TO_CEILING_KEY = {
    "battery": "battery",
    "fault": "fault_current",   # 3-A: 헤드라인 = 신세대 22개만 (풀링 n=40 금지)
    "zonecore": "zone",
    "zone": "zone",
}


def oracle_ceiling_summary_for_case(case, ceilings):
    """3-C 단일 진실원: `ceilings`(=`build_md_report.compute_ceilings()` 의 반환값)에서 이 case 에
    해당하는 축 summary 를 꺼낸다. 재구현하지 않는다 -- 값의 출처는 오직 build_md_report.py 뿐이다."""
    key = CASE_TO_CEILING_KEY.get(case)
    if key is None:
        return None
    return (ceilings or {}).get(key)


def render_row_cells(row_label, case, json_data, ceilings):
    if row_label == "oracle":
        if case not in CASE_TO_CEILING_KEY:
            # 다종(kind) 혼합 case -- 단일축 오라클 격자가 아예 없다. STEP D 로도 채울 수 없는
            # 결측이므로 MISSING_TOKEN 이 아니라 NA_MIXED_KIND_TOKEN (둘 다 REPORT.md/FINAL.md 가
            # 여기 이 한 함수를 공유해서 렌더링한다 -- 분기 로직을 두 문서에서 중복하지 않는다).
            return [NA_MIXED_KIND_TOKEN, "100% (정의상)", DASH, DASH]
        summary = oracle_ceiling_summary_for_case(case, ceilings)
        if summary is None:
            return [MISSING_TOKEN, "100% (정의상)", DASH, DASH]
        # [2026-08-14] 라벨 파일은 있는데 그 축의 instance 를 하나도 J 로 못 잰 경우.
        # fault/zone kind 라벨 행에는 energy_J 가 없다(배터리 레이어가 battery instance 에서만
        # 켜진다) -- 그런 축을 0% 완주로 렌더하면 "천장이 0%" 라는 거짓 주장이 표에 실린다.
        # 채점 불가 수를 이름으로 남긴다.
        if summary.get("scored", summary["n"]) == 0:
            return ["%s — J 채점 불가 %d instance (energy_J 없음)"
                    % (MISSING_TOKEN, summary.get("unscorable", 0)),
                    "100% (정의상)", DASH, DASH]
        completion = fmt_pct(summary["completion_rate"], summary["n_complete"], summary["n"])
        if summary.get("unscorable", 0):
            completion += " ⚠︎J채점불가 %d 제외" % summary["unscorable"]
        if summary.get("mean_makespan") is not None:
            btime = "%.1f (완주판 n=%d)" % (summary["mean_makespan"], summary["n_makespan_arms"])
        else:
            btime = DASH
        return [completion, "100% (정의상)", btime, DASH]
    pol_key = dict(ROW_ORDER)[row_label]
    policies = (json_data or {}).get("policies") or {}
    d = policies.get(pol_key)
    if d is None:
        return ["정책 없음 (case 데이터에 `%s` 미포함)" % pol_key, DASH, DASH, DASH]
    completion = "%d/%d" % (d.get("n_complete", 0), d.get("n", 0))
    decision = fmt_pct(d.get("decision_rate"), d.get("n_decisions_correct"), d.get("n_decisions_scored"))
    btime = fmt_time(d.get("sim_seconds_complete"), d.get("sim_seconds_sd"))
    energy = fmt_num(d.get("energy_per_closed"))
    return [completion, decision, btime, energy]


ROW_LABEL_TEXT = {
    "oracle": "`oracle` (천장·비실행)",
    "surrogate": "`surrogate`",
    "noop": "`noop` (바닥선)",
    "llm": "`llm` (dspy)",
}


def render_case_block(case, case_info, artifacts, py, ceilings):
    lines = []
    has_data = case_info["has_data"]
    status = case_info["status"]

    boards = dedup_boards(case_info["raw_rows"]) if has_data else []

    if not has_data:
        lines.append("### case = %s   (데이터 없음)" % case)
        lines.append("")
        status_txt = ("status_4pol.jsonl 최신 기록: status=%s rows=%s wall_seconds=%s"
                      % (status.get("status"), status.get("rows"), status.get("wall_seconds"))) \
            if status else "status_4pol.jsonl 에 이 case 기록 없음 (스윕이 아직 이 case 에 도달하지 않음)."
        lines.append("**데이터 없음.** %s" % status_txt)
        lines.append("")
        lines.append(ORACLE_NOTE)
        lines.append("")
        return lines, boards

    n_seeds = len({b.get("ood_seed") for b in boards}) if boards else 0
    world_seeds = sorted({b.get("world_seed") for b in boards if b.get("world_seed") is not None})
    routers = sorted({str(b.get("router")) for b in boards if b.get("router") is not None})
    world_seed_str = str(world_seeds[0]) if len(world_seeds) == 1 else ("mixed:%s" % world_seeds if world_seeds else "?")
    router_str = routers[0] if len(routers) == 1 else ("mixed:%s" % routers if routers else "?")

    lines.append("### case = %s   (n=%d seeds, world_seed=%s, router=%s)" % (case, n_seeds, world_seed_str, router_str))
    lines.append("")

    if case_info["n_bad_lines"]:
        lines.append("(참고: 원본 파일에서 파싱 안 되는 줄 %d개를 건너뜀 -- 스윕이 지금 이 파일에 "
                      "쓰는 중이라 마지막 줄이 잘렸을 수 있다.)" % case_info["n_bad_lines"])
        lines.append("")

    lines.append(ORACLE_NOTE)
    lines.append("")

    if not artifacts["report_ok"]:
        lines.append("**`llm_ood_eval.py report` 실패 -- 이 case 의 수치표를 만들 수 없다.**")
        lines.append("")
        lines.append("```")
        lines.append(artifacts["report_err"] or "(사유 불명)")
        lines.append("```")
        lines.append("")
        return lines, boards

    json_data = artifacts["json_data"]
    lines.append("| 정책 | 완주율 | 옳은 결정 (vs oracle a*) | 빌드 시간(완주판) | J/closed |")
    lines.append("|---|---|---|---|---|")
    for label, _key in ROW_ORDER:
        cells = render_row_cells(label, case, json_data, ceilings)
        lines.append("| %s | %s |" % (ROW_LABEL_TEXT[label], " | ".join(cells)))
    lines.append("")

    if case == "fault":
        fault_legacy = (ceilings or {}).get("fault_legacy")
        if fault_legacy is not None:
            lines.append(
                "> **3-A** -- 위 `oracle` 행의 완주율은 22개 **현재-세대** fault instance 만 반영한다"
                "(`firegrid_s{fault,faultidle}.jsonl`, NOOP/Replace 2-arm 메뉴). 구세대 18개 instance"
                "(5-arm 메뉴, macro 7/8 이전 라벨 -- CLAUDE.md \"성능 근거 아님\")는 헤드라인에서 제외"
                "했다 -- 참고용 완주율 %s. **이 둘을 풀링한 n=40 천장은 이 문서에 없다** "
                "(`artifacts_4pol/REPORT.md` §3-A 상세)."
                % fmt_pct(fault_legacy["completion_rate"], fault_legacy["n_complete"], fault_legacy["n"]))
            lines.append("")
    elif case in ("zonecore", "zone"):
        lines.append(
            "> **3-B 참고** -- `reference_policy.py` 의 zone 규칙은 root-covered 영역(`cov` 계열)에서 "
            "오라클과 어긋난다는 결함이 STEP D 로 드러났다. 이 case 를 포함한 8-case 스윕 전체에는 그 "
            "영역의 결정이 0건이라(전부 root_covered==0) 위 표의 zone 관련 숫자는 영향받지 않는다 -- "
            "결함 상세는 `artifacts_4pol/REPORT.md` §3-B.")
        lines.append("")

    if artifacts["shadow_ok"]:
        lines.append("shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_%s.md` "
                      "-- 완주/시간/에너지 주장에는 쓰지 말 것." % case)
    else:
        lines.append("shadow 채점 실패 (case=%s): %s" % (case, (artifacts.get("shadow_err") or "")[:300]))
    lines.append("")

    lines.append("<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · "
                  "escalation/novelty · 짝비교 부호검정)</summary>")
    lines.append("")
    lines.append(artifacts.get("md_text") or "(비어 있음)")
    lines.append("</details>")
    lines.append("")
    return lines, boards


def build_final_md(results_dir, out_dir, cases_info, all_artifacts, pooled_shadow, status_by_case,
                    status_n_bad, status_path, py, args, ceilings):
    now = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    L = []
    L.append("# 4정책 x OOD case 비교표 -- FINAL (자동 생성)")
    L.append("")
    L.append("생성 시각: %s" % now)
    L.append("생성기: `build_final_table.py --results-dir %s --out-dir %s`" % (results_dir, out_dir))
    L.append("")
    L.append(ORACLE_NOTE)
    L.append("")
    L.append("실행 가능한 lane 은 `noop` / `surrogate` / `dspy`(=`llm`) 셋뿐이다(이번 스윕이 실제로 "
              "돌린 정책 집합과 같다). `oracle` 행은 매 블록에서 별도 계산되는 상한선으로만 들어간다.")
    L.append("")
    L.append("기준 행동 a* 의 출처 (반사실 오라클이 아니라 격자 실측에서 유도한 기준 정책):")
    for k, v in reference_policy.BASIS.items():
        L.append("- `%s`: %s" % (k, v))
    L.append("")
    if pooled_shadow.get("ok"):
        L.append("전체 pooled shadow 채점(모든 case 합산, 새 시뮬 0회): `artifacts_4pol/shadow.md`")
    else:
        L.append("전체 pooled shadow 채점 건너뜀/실패: %s" % pooled_shadow.get("err"))
    L.append("")
    L.append("---")
    L.append("")
    L.append("## Case 블록")
    L.append("")

    per_case_boards = {}
    for case in CASES:
        block_lines, boards = render_case_block(case, cases_info[case], all_artifacts.get(case, {}), py,
                                                  ceilings)
        per_case_boards[case] = boards
        L.extend(block_lines)
        L.append("---")
        L.append("")

    L.append("## Post-hoc validation (V1-V4)")
    L.append("")
    L.append("V1 LLM lane 이 진짜인지(canonical 로 조용히 폴백된 것이 아닌지) · V2 noop 이 정말 noop 인지 "
              "· V3 빈 board 가 없는지 · V4 판 수가 (시드 수 x 정책 수) 인지. 아래 각 case 마다 "
              "네 줄씩 반드시 찍는다(조용한 생략 금지).")
    L.append("")
    for case in CASES:
        L.append("### case = %s" % case)
        if not cases_info[case]["has_data"]:
            L.append("- 데이터 없음 -- V1-V4 해당 없음.")
            L.append("")
            continue
        for line in validate_case(case, per_case_boards[case]):
            L.append("- %s" % line)
        L.append("")

    L.append("---")
    L.append("")
    L.append("## 누락 및 한계")
    L.append("")
    L.append("### 이번 실행에서 빠지거나 실패한 case (조용한 절삭 금지 -- 이름으로 남긴다)")
    missing_any = False
    for case in CASES:
        ci = cases_info[case]
        art = all_artifacts.get(case)
        if not ci["has_data"]:
            st = ci["status"]
            reason = ("status=%s rows=%s" % (st.get("status"), st.get("rows"))) if st else "status 기록 없음"
            L.append("- `%s`: 데이터 없음 (%s)." % (case, reason))
            missing_any = True
        elif art and not art.get("report_ok"):
            L.append("- `%s`: 데이터는 있으나 `llm_ood_eval.py report` 실패로 표를 못 만듦."
                      % case)
            missing_any = True
        elif art and not art.get("shadow_ok"):
            L.append("- `%s`: 수치표는 있으나 shadow_score.py 실패." % case)
            missing_any = True
    if not missing_any:
        L.append("- 없음 -- 8개 case 전부 데이터 있고 report/shadow 정상 생성됨.")
    if status_n_bad:
        L.append("- (참고) `_night/status_4pol.jsonl` 에서 파싱 안 되는 줄 %d개를 건너뜀." % status_n_bad)
    L.append("")
    L.append("### 구조적 한계 (항상 참, plan §11)")
    # has-data case 만 넘긴다 -- 데이터 없는 case 가 하나라도 섞이면 그 case 의 boards=[] 가
    # n_seeds_by_case 에 0 으로 들어가 min() 이 0 으로 무너진다("시드 0개, 최소 p=1.000") --
    # build_md_report.py:326-333 과 같은 필터링 (fix round 2, 2026-08-11 코드리뷰 지적).
    populated_boards = {c: bs for c, bs in per_case_boards.items() if bs}
    L.extend(limitations_lines(populated_boards)[2:])  # [0:2] = "## 7. 한계","" 헤더 -- 이 절은 위에서 이미 찍었다
    return "\n".join(L) + "\n"


# =====================================================================================
# main
# =====================================================================================
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--results-dir", default="results_4pol")
    ap.add_argument("--out-dir", default="artifacts_4pol")
    ap.add_argument("--oracle-dir", default="oracle/out")
    args = ap.parse_args()

    results_dir = resolve_path(args.results_dir)
    out_dir = resolve_path(args.out_dir)
    oracle_dir = resolve_path(args.oracle_dir)
    night_dir = resolve_path("_night")
    out_dir.mkdir(parents=True, exist_ok=True)
    py = sys.executable

    print("results-dir = %s" % results_dir)
    print("out-dir     = %s" % out_dir)
    print("oracle-dir  = %s" % oracle_dir)

    # 3-C 단일 진실원: 오라클 축 천장(battery/fault/zone) 계산은 build_md_report.py 에만 있다 -- 여기서
    # 재구현하지 않고 지연 import 로 그 함수를 그대로 쓴다. (지연 import 인 이유: build_md_report.py
    # 는 모듈 최상단에서 `import build_final_table as BFT` 를 하므로, 이 파일이 최상단에서 반대로
    # build_md_report 를 import 하면 순환 임포트가 된다. 함수 안에서, 즉 이 모듈의 최상단 정의가 모두
    # 끝난 시점에만 import 하면 어느 쪽이 먼저 실행되든 안전하다.)
    import build_md_report as BMR  # noqa: E402  (지연 import, 순환 임포트 회피)
    ceilings = BMR.compute_ceilings(oracle_dir)

    cases_info, status_by_case, status_n_bad, status_path = discover_cases(results_dir, night_dir)

    all_artifacts = {}
    data_case_paths = []
    for case in CASES:
        ci = cases_info[case]
        if not ci["has_data"]:
            print("[%s] 데이터 없음 (건너뜀)" % case)
            continue
        print("[%s] report+shadow 생성 중 (rows=%d, bad_lines=%d)..."
              % (case, len(ci["raw_rows"]), ci["n_bad_lines"]))
        art = build_case_artifacts(ci, out_dir, py)
        all_artifacts[case] = art
        if art["report_ok"]:
            data_case_paths.append(ci["path"])
            print("  report OK -> %s/%s.json" % (out_dir.name, case))
        else:
            print("  report FAILED: %s" % (art["report_err"] or "")[:300])
        if art.get("shadow_ok"):
            print("  shadow OK -> %s/shadow_%s.md" % (out_dir.name, case))
        else:
            print("  shadow FAILED: %s" % (art.get("shadow_err") or "")[:300])

    # task 6, 2-pass: 모든 case 의 paired_tests 가 다 모인 지금에야 Holm 을 족(21 검정) 전체에 적용
    # 할 수 있다 -- case 하나씩 처리하는 위 루프 안에서는 아직 다른 case 의 p 값을 모른다.
    apply_holm_correction(all_artifacts, out_dir)

    pooled_shadow = build_pooled_shadow(data_case_paths, out_dir, py)
    if pooled_shadow.get("ok"):
        print("pooled shadow OK -> %s/shadow.md" % out_dir.name)
    else:
        print("pooled shadow: %s" % pooled_shadow.get("err"))

    final_text = build_final_md(results_dir, out_dir, cases_info, all_artifacts, pooled_shadow,
                                 status_by_case, status_n_bad, status_path, py, args, ceilings)
    final_path = out_dir / "FINAL.md"
    final_path.write_text(final_text, encoding="utf-8")
    print("\nFINAL -> %s" % final_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
