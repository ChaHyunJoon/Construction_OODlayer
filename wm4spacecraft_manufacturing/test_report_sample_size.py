"""test_report_sample_size.py -- 리포트가 자기 표본 크기를 하드코딩하지 않는다는 회귀 테스트.

실행: /home/chahj578/Construction_OODlayer/.venv/bin/python test_report_sample_size.py

이 파일이 막는 결함: 표는 n=20 을 보여주는데 산문은 "시드 5개, 최소 p=0.062" 라고
적혀 있는 자가당착 문서(2026-08-11 실측: build_final_table.py:55, build_md_report.py:649, :684).
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import build_final_table
import build_md_report

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  %s  %s   %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILED += 1


def _boards(n_seeds, policies=("noop", "surrogate", "dspy")):
    return [{"ood_seed": s, "policy": p, "world_seed": 1}
            for s in range(1, n_seeds + 1) for p in policies]


print("== 리포트 표본크기 하드코딩 회귀 테스트 ==")

body = "\n".join(build_final_table.limitations_lines({"battery": _boards(20)}))
check("한계 문구가 실제 시드 수를 쓴다", "시드 5개" not in body and "20" in body)
# n=20 짝이면 부호검정 하한은 2*0.5^20 = 1.9e-06 이다. n=5 의 0.062 가 아니다.
check("부호검정 하한이 계산된 값이다", "0.062" not in body)
# world_seed 는 이번에도 고정이다 -- 이 한계는 지워지면 안 된다.
check("world_seed 한계가 남아 있다", "world_seed" in body)
# 두 빌더가 같은 문구를 각자 들고 있으면 한쪽만 고쳐도 테스트가 통과해버린다.
check("build_md_report 가 단일 진실원에 위임한다",
      build_md_report.BFT.limitations_lines is build_final_table.limitations_lines)

# 빈 case 가 섞여도 n_seeds 가 0 으로 무너지면 안 된다(20시드 스윕이 zonecore 를 일부러 빼므로
# 실제로 벌어지는 입력이다 -- fix round 2, 2026-08-11 코드리뷰 지적).
mixed_body = "\n".join(build_final_table.limitations_lines(
    {"battery": _boards(20), "zonecore": []}))
check("빈 case 가 섞여도 시드 수가 0 으로 무너지지 않는다",
      "시드 0개" not in mixed_body and "20" in mixed_body, mixed_body.splitlines()[0])

rb = "\n".join(build_final_table.repro_lines(
    420, list(range(1, 21)),
    ["battery", "fault", "all", "fault_battery", "fault_zone", "battery_zone", "zone"]))
# 주의: "--seeds 1,2,3,4,5" 는 20시드 문자열의 **접두사**라 `not in` 으로 검사하면 언제나
# 실패한다(2026-08-11 실측). 정확히 5시드로 끝나는 경우만 잡아야 한다.
check("재현 절차가 실제 시드 목록을 쓴다",
      not re.search(r"--seeds 1,2,3,4,5(?![\d,])", rb)
      and "1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20" in rb
      and "420" in rb)

v4 = "\n".join(build_final_table.check_v4(_boards(20)))
check("V4 기대판수가 동적이다", "PASS" in v4 and "60" in v4 and "15" not in v4, v4)
check("V4 가 판 부족을 잡는다", "WARN" in "\n".join(build_final_table.check_v4(_boards(20)[:-1])))

# 문자열 리터럴로 남은 표본크기 주장을 통째로 금지한다. 두 파일 모두 검사한다 --
# 같은 문장이 양쪽에 복사돼 있어서(2026-08-11 실측) 한쪽만 고치면 샌다.
for fn in ("build_md_report.py", "build_final_table.py"):
    src = open(os.path.join(HERE, fn), encoding="utf-8").read()
    check("%s 에 표본크기 리터럴 없음" % fn,
          "시드 5개" not in src and "0.062" not in src
          and not re.search(r"5 seeds x 3 policies", src))

_rows = []
for _s in range(1, 21):
    _rows.append({"ood_seed": _s, "policy": "noop", "complete": False,
                  "battery": {"energy_per_closed": 900.0}, "sim_seconds": None})
    _rows.append({"ood_seed": _s, "policy": "dspy", "complete": True,
                  "battery": {"energy_per_closed": 400.0}, "sim_seconds": 25.0})
_out = build_final_table.paired_tests(_rows)
_k = "noop__dspy"
check("case 별 짝검정이 나온다",
      _k in _out                             # 0승 20패 -> 유의 (sign p = 1.9e-06)
      and _out[_k]["e1_sign_p"] < 0.05
      and _out[_k]["e3_wilcoxon_p"] < 0.05   # 에너지 일관되게 낮음
      and bool(_out[_k]["e4_note"]),         # noop 완주 0 -> 빌드시간 정의 불가
      "e1=%.3g e3=%.3g" % (_out[_k]["e1_sign_p"], _out[_k]["e3_wilcoxon_p"]) if _k in _out else "missing")

_fam = {"battery__noop__dspy": 0.01, "fault__noop__dspy": 0.04, "zone__noop__dspy": 0.5}
_adj = build_final_table.holm_family(_fam)
check("Holm 이 case x pair 족 전체에 적용된다",
      abs(_adj["battery__noop__dspy"] - 0.03) < 1e-9      # 0.01 * 3
      and abs(_adj["zone__noop__dspy"] - 0.5) < 1e-9,     # 0.5 * 1
      str(_adj))

# 코드리뷰 fix round 1: 두 정책이 매판 완주(E1 전부 동점)하고 에너지도 매판 동일(E3 전부 동점)한
# 픽스처 -- `t and not (w or l)` 이 미래에 느슨해져도(예: `w+l+t`) 조용히 안 깨지게 직접 겨눈다.
_rows_ceiling = []
for _s in range(1, 6):
    for _p in ("noop", "surrogate", "dspy"):
        _rows_ceiling.append({"ood_seed": _s, "policy": _p, "complete": True,
                              "battery": {"energy_per_closed": 500.0}, "sim_seconds": 30.0})
_out_ceiling = build_final_table.paired_tests(_rows_ceiling)
_kc = "noop__surrogate"
check("E1 전부 동점이면 천장 문구가 붙는다 (0승0패 만으로는 부족, 무승부 존재까지 본다)",
      _out_ceiling[_kc]["e1_wins"] == 0 and _out_ceiling[_kc]["e1_losses"] == 0
      and _out_ceiling[_kc]["e1_ties"] == 5
      and _out_ceiling[_kc]["e1_note"] == "천장(전부 동점) -- 시드를 늘려도 유의해질 수 없다",
      str(_out_ceiling[_kc]["e1_note"]))
check("E3 에너지가 전부 동일하면 천장 문구가 붙는다 (e4 처럼 note 를 흘리지 않는다)",
      _out_ceiling[_kc]["e3_note"] == "전부 동점 -- 검정 불가(ceiling)",
      str(_out_ceiling[_kc]["e3_note"]))

sys.exit(1 if FAILED else 0)
