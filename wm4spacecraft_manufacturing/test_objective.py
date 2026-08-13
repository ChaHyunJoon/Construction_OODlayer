#!/usr/bin/env python3
"""목적함수 J 의 계약 검사 (spec §9). 시뮬레이션 없이 도는 순수 단위검사.

    .venv/bin/python test_objective.py     # exit 0 = 전부 통과
"""
import math
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import objective  # noqa: E402

FAILED = []


def check(name, ok, detail=""):
    print(("PASS  " if ok else "FAIL  ") + name + (("  — " + str(detail)) if detail else ""))
    ok or FAILED.append(name)


CFG = objective.load()
# 스케일이 채워져 있어야 완주 분기를 검사할 수 있다.
HAVE_SCALES = all(CFG.get(k) is not None for k in objective.SCALE_KEYS)


def better_ssp(a, b):
    """gen_oracle_mc.jl:165 의 사전식 순위. a 가 b 보다 나으면 True."""
    if a["complete"] != b["complete"]:
        return a["complete"]
    if a["complete"]:
        return a["makespan"] < b["makespan"]
    if a["closed"] != b["closed"]:
        return a["closed"] > b["closed"]
    return a["makespan"] < b["makespan"]


def run(r):
    return objective.J(complete=r["complete"], closed=r["closed"], total=r["total"],
                       makespan=r["makespan"], energy_J=r.get("energy_J"))


# ---- 1) 순서동치(경계 + 미완주 내부) — argmin J 가 better_ssp 1등을 재현하는가 (spec §9) ------
# 아래 5 case 의 완주 케이스 둘은 energy_J 가 서로 같다(E) — 그래서 이 검사는 "완주/미완주
# 경계"와 "미완주 내부"에서만 J 와 better_ssp 의 순서가 일치하는지를 본다. 완주끼리 에너지가
# 다를 때는 J 가 better_ssp 와 **의도적으로** 갈릴 수 있다 — 그 경계는 검사 1b 가 정확히
# κ 예산(w_E·ΔE) 단위로 따로 검증한다. 이 검사를 "완전한 순서동치 증명"으로 읽으면 안 된다.
if HAVE_SCALES:
    E = CFG["E_ref"]
    cases = [
        dict(complete=True,  closed=300, total=300, makespan=900.0, energy_J=E),
        dict(complete=False, closed=299, total=300, makespan=10.0),
        dict(complete=False, closed=250, total=300, makespan=500.0),
        dict(complete=False, closed=200, total=300, makespan=500.0),
        dict(complete=True,  closed=300, total=300, makespan=800.0, energy_J=E),
    ]
    ssp_best = cases[0]
    for c in cases[1:]:
        if better_ssp(c, ssp_best):
            ssp_best = c
    j_best = min(cases, key=run)
    check("순서동치(경계+미완주 내부, 완주 케이스는 에너지 동일): argmin J == better_ssp 1등",
          (j_best["complete"], j_best["closed"], j_best["makespan"])
          == (ssp_best["complete"], ssp_best["closed"], ssp_best["makespan"]),
          "J=%r ssp=%r" % (j_best, ssp_best))

    # ---- 1b) 완주 내부 순서 — J 는 better_ssp(makespan 만) 과 최대 κ·ΔE/E_ref 만큼만 갈린다 ----
    # 대수: J_A - J_B = (mkA-mkB) + w_E*(E_A-E_B). better_ssp 는 mkA vs mkB 만 본다. 그러므로
    # |mkA-mkB| 가 w_E*|E_A-E_B| ("κ 예산", ΔE=E_A-E_B)를 넘으면 두 순위가 반드시 일치하고,
    # 그 이내면 에너지 항이 이겨 갈릴 수 있다 — 이게 spec §4.1 이 원하는 "κ 는 작은 동점해소자"
    # 의 정확한 의미이자, 리뷰가 지적한 실제 사례(비교 예: (M_ref,2E_ref) vs (1.005·M_ref,E_ref))
    # 가 일어나는 이유다. 예산 안/밖 양쪽을 모두 확인해야 "J 가 better_ssp 와 다르다"는 사실이
    # 버그가 아니라 설계라는 걸 검사가 증명한다.
    mkA = CFG["M_ref"]
    dE = E  # A 가 B 보다 에너지를 E_ref 만큼 더 쓴다(E_A=2E, E_B=E) → ΔE/E_ref == 1
    crossover = objective.energy_weight(CFG) * dE  # = w_E*ΔE = kappa*M_ref (recalibration-safe)

    mkB_over = mkA + 1.1 * crossover
    Ja_over = objective.J(complete=True, closed=300, total=300, makespan=mkA, energy_J=2 * E)
    Jb_over = objective.J(complete=True, closed=300, total=300, makespan=mkB_over, energy_J=E)
    check("완주 내부: makespan 차이가 κ 예산(w_E·ΔE)을 넘으면 better_ssp 와 일치(더 빠른 쪽이 이긴다)",
          Ja_over < Jb_over,
          "Ja=%.6f(mk=%.4f,E=2E) Jb=%.6f(mk=%.4f,E=E) crossover=%.6f"
          % (Ja_over, mkA, Jb_over, mkB_over, crossover))

    mkB_under = mkA + 0.9 * crossover  # better_ssp 는 여전히 A 승(mkA < mkB_under)
    Ja_under = objective.J(complete=True, closed=300, total=300, makespan=mkA, energy_J=2 * E)
    Jb_under = objective.J(complete=True, closed=300, total=300, makespan=mkB_under, energy_J=E)
    check("완주 내부: makespan 차이가 κ 예산 이내면 better_ssp 와 갈릴 수 있다"
          "(에너지가 이긴다, 의도된 동작 — spec §4.1)",
          Jb_under < Ja_under and mkA < mkB_under,
          "Ja=%.6f(mk=%.4f,E=2E) Jb=%.6f(mk=%.4f,E=E) crossover=%.6f"
          % (Ja_under, mkA, Jb_under, mkB_under, crossover))

    # ---- 2) 실패 보상 없음 — 관측 분포 밖(median+5σ) 완주도 실패보다 낮고, 안전 여유가 크다 ----
    # spec §9 는 "미완주 J 가 완주 J 보다 낮은 경우가 있으면 즉시 실패"라고 문자 그대로 읽으면
    # 어떤 유한벌점 목적함수로도 지킬 수 없다(에너지·makespan 이 이론상 무한히 나빠질 수 있으므로
    # 항상 반례를 만들 수 있다). spec §3 은 그 유한벌점(SSP) 자체를 요구하므로 §3 과 §9 가 문자
    # 그대로는 동시에 성립할 수 없다 — 이 구현은 §3 을 따르고, "실패 보상 없음"을 **관측 가능한
    # 범위** 에서의 안전 여유로 재정의한다(§9 의 의도는 지키되 무한대에 대해 증명하지 않는다).
    #
    # 이전 버전은 "최악의 완주"를 3×M_ref/3×E_ref 라는 매direct 수로 정의했다 — κ 나 C_fail 이
    # 재교정되면 그 매직넘버가 왜 여전히 안전한지 알 길이 없다. 대신 두 가지를 직접 검사한다:
    #   (a) 안전 여유를 배수(margin)로 명시적으로 측정한다 — 재교정되면 이 수가 줄어드는 게
    #       바로 보이므로 "위험 구간"에 들어가면 검사가 시끄럽게 실패한다.
    #   (b) 관측된 분포(calibrated_from 의 median/stdev)를 훨씬 넘는(5-시그마) "매우 나쁘지만
    #       있을 법한" 완주가 여전히 실패를 이기는지 직접 확인한다.
    cal = CFG.get("calibrated_from") or {}
    makespan_tail = cal.get("makespan_median", CFG["M_ref"]) + 5.0 * cal.get("makespan_stdev", 0.0)
    energy_tail = cal.get("energy_median", CFG["E_ref"]) + 5.0 * cal.get("energy_stdev", 0.0)

    w_E = objective.energy_weight(CFG)
    # crossover_makespan: energy=E_ref 인 완주 런이 C_fail 과 정확히 비기는 makespan.
    # (best_fail = C_fail, closed==total 이고 makespan=0 인 미완주의 J.)
    crossover_makespan = CFG["C_fail"] - w_E * CFG["E_ref"]
    MARGIN_MIN = 50.0
    margin = (crossover_makespan / makespan_tail) if makespan_tail > 0 else float("inf")
    check("실패 보상 안전 여유: crossover_makespan / (median+5σ makespan) ≥ %gx" % MARGIN_MIN,
          margin >= MARGIN_MIN,
          "crossover_makespan=%.3f makespan_tail=%.3f margin=%.1fx" % (crossover_makespan, makespan_tail, margin))

    best_fail = run(dict(complete=False, closed=300, total=300, makespan=0.0))
    worst_plausible_complete = run(dict(complete=True, closed=300, total=300,
                                        makespan=makespan_tail, energy_J=energy_tail))
    check("실패 보상 없음: 관측 분포 밖(median+5σ) 완주도 최선의 미완주보다 낮다",
          worst_plausible_complete < best_fail,
          "worst_plausible_complete=%.3f best_fail=%.3f" % (worst_plausible_complete, best_fail))

    # ---- 3) 에너지는 완주 분기에만 (spec §3.1) ----
    a = objective.J(complete=False, closed=250, total=300, makespan=500.0)
    b = objective.J(complete=False, closed=250, total=300, makespan=500.0, energy_J=1e9)
    check("미완주 J 는 energy_J 를 무시한다", a == b, "%.6f vs %.6f" % (a, b))

    # ---- 4) 에너지가 J 를 실제로 움직이는가 (동점해소자로서 살아 있는가, spec §4.2) ----
    lo = objective.J(complete=True, closed=300, total=300, makespan=100.0, energy_J=E)
    hi = objective.J(complete=True, closed=300, total=300, makespan=100.0, energy_J=2 * E)
    check("같은 makespan 이면 에너지가 적은 쪽이 이긴다", lo < hi, "%.6f < %.6f" % (lo, hi))

    # ---- R-1a) κ 는 동점해소자 크기다 — 양방향 crossover 를 kappa 로부터 직접 유도해 검증 ----
    # 일반식: faster = (1-f)*M_ref + w_E*2E, slower = M_ref + w_E*E, w_E*E = kappa*M_ref 이므로
    # faster < slower ⟺ f > kappa. 이전 버전은 f=1%(=kappa 자체) 를 하드코딩했는데, kappa=0.01
    # 인 한 그건 정확히 등식이 되는 경계값이라 늘 실패했다(구현 버그가 아니라 우연한 경계
    # 일치). 이제 kappa 의 절반/두 배로 양쪽을 검사한다 — kappa 가 재교정돼도 그대로 성립한다.
    kappa = CFG["kappa"]
    slower = objective.J(complete=True, closed=300, total=300, makespan=CFG["M_ref"], energy_J=E)

    f_lo = 0.5 * kappa
    faster_lo = objective.J(complete=True, closed=300, total=300,
                            makespan=CFG["M_ref"] * (1.0 - f_lo), energy_J=2 * E)
    check("f=0.5κ: 에너지가 이긴다(작은 속도 우위는 에너지 2배를 못 이긴다)",
          slower < faster_lo, "slower=%.6f faster_lo=%.6f f=%.5f kappa=%r" % (slower, faster_lo, f_lo, kappa))

    f_hi = 2.0 * kappa
    faster_hi = objective.J(complete=True, closed=300, total=300,
                            makespan=CFG["M_ref"] * (1.0 - f_hi), energy_J=2 * E)
    check("f=2κ: 속도가 이긴다(충분한 속도 우위는 에너지 2배를 이긴다)",
          faster_hi < slower, "faster_hi=%.6f slower=%.6f f=%.5f kappa=%r" % (faster_hi, slower, f_hi, kappa))
else:
    check("스케일 미측정 — 완주 분기 검사 건너뜀 (objective.json 의 M_ref/E_ref 가 null)", True)

# ---- 5) null 스케일이면 에러, 조용한 폴백 없음 (spec §5) ----
null_cfg = dict(CFG)
null_cfg["M_ref"] = None
try:
    objective.J(complete=True, closed=1, total=1, makespan=10.0, energy_J=5.0, cfg=null_cfg)
    check("null 스케일 → 에러", False, "에러가 안 났다")
except objective.ObjectiveError:
    check("null 스케일 → 에러", True)

# ---- M-5) 미완주 분기의 C_fail/C_unclosed/tie_eps 가 null 이면 ObjectiveError (TypeError 아님) ----
for key in objective.INCOMPLETE_KEYS:
    bad_cfg = dict(CFG)
    bad_cfg[key] = None
    try:
        objective.J(complete=False, closed=1, total=2, makespan=1.0, cfg=bad_cfg)
        check("미완주 분기: %s null → ObjectiveError" % key, False, "에러가 안 났다")
    except objective.ObjectiveError:
        check("미완주 분기: %s null → ObjectiveError" % key, True)
    except Exception as e:  # noqa: BLE001 — TypeError/기타가 새는지 명시적으로 잡아 실패시킨다
        check("미완주 분기: %s null → ObjectiveError" % key, False,
              "ObjectiveError 가 아닌 다른 예외가 샜다: %r" % (e,))

# ---- 6) 완주인데 energy 없음 → 에러 ----
try:
    objective.J(complete=True, closed=1, total=1, makespan=10.0, energy_J=None)
    check("완주 + energy 없음 → 에러", False, "에러가 안 났다")
except objective.ObjectiveError:
    check("완주 + energy 없음 → 에러", True)

# ---- I-1) closed > total (장부 드리프트)이어도 (total-closed) 는 0 밑으로 안 내려간다 -------
# gen_oracle_mc.jl:146 은 이 항을 클램프하지 않는다. 이 하니스에서 complete==true 인데도
# closed<total 인 장부 노드가 있을 수 있다는 건 CLAUDE.md(§6 완주 ≠ closed==total)에 이미
# 문서화돼 있다 — 그 역(기록 드리프트로 closed>total)도 배제할 근거가 없다. 클램프가 없으면
# 이 항이 음수가 돼 미완주 J 가 임의로 낮아질 수 있고, 극단적으로는 어떤 완주 런보다도
# 낮아져 "기록 오류가 세상에서 가장 좋은 결과"가 될 수 있다.
overclosed = objective.J(complete=False, closed=400, total=300, makespan=0.0)
check("closed>total 이어도 (total-closed) 는 0 밑으로 안 내려간다(클램프): J == C_fail",
      overclosed == CFG["C_fail"], "overclosed J=%r (기대: C_fail=%r)" % (overclosed, CFG["C_fail"]))
if HAVE_SCALES:
    check("closed>total 인 미완주 J 가 관측 분포 밖(median+5σ) 최악의 완주보다 낮아지지 않는다",
          overclosed > worst_plausible_complete,
          "overclosed=%.3f worst_plausible_complete=%.3f" % (overclosed, worst_plausible_complete))

# ---- I-2) J_row: complete/closed/total 스키마 드리프트는 에러, 있으면 J() 와 정확히 같다 -----
for missing_key in ("complete", "closed", "total"):
    row = {"complete": True, "closed": 1, "total": 1, "makespan": 1.0, "energy_J": 1.0}
    del row[missing_key]
    try:
        objective.J_row(row)
        check("J_row: %s 없으면 에러" % missing_key, False, "에러가 안 났다")
    except objective.ObjectiveError:
        check("J_row: %s 없으면 에러" % missing_key, True)

try:
    objective.J_row({})
    check("J_row: 빈 행이면 에러(예전엔 False/0/0 폴백으로 10000.0 을 냈다)", False, "에러가 안 났다")
except objective.ObjectiveError:
    check("J_row: 빈 행이면 에러(예전엔 False/0/0 폴백으로 10000.0 을 냈다)", True)

row_fail = {"complete": False, "closed": 250, "total": 300, "sim_seconds": 500.0}
check("J_row: 미완주 행(정상 스키마, sim_seconds 폴백) — J() 와 값이 같다",
      objective.J_row(row_fail) == objective.J(complete=False, closed=250, total=300, makespan=500.0),
      objective.J_row(row_fail))

if HAVE_SCALES:
    row_ok = {"complete": True, "closed": 300, "total": 300, "sim_seconds": CFG["M_ref"],
              "battery": {"total_energy_J": CFG["E_ref"]}}
    expect = objective.J(complete=True, closed=300, total=300, makespan=CFG["M_ref"], energy_J=CFG["E_ref"])
    got = objective.J_row(row_ok)
    check("J_row: 완주 행(battery.total_energy_J + sim_seconds 폴백) — J() 와 값이 같다",
          abs(got - expect) < 1e-9, "%.6f vs %.6f" % (got, expect))

# ---- 7) 현행 상수를 그대로 물려받았는가 (gen_oracle_mc.jl:142-144) ----
check("C_fail == 10000.0", CFG["C_fail"] == 10000.0, CFG["C_fail"])
check("C_unclosed == 100.0", CFG["C_unclosed"] == 100.0, CFG["C_unclosed"])
check("tie_eps == 1.0e-3", abs(CFG["tie_eps"] - 1.0e-3) < 1e-12, CFG["tie_eps"])

# ---- 8) ENV 덮어쓰기가 해시를 가른다 (spec §5, §7) ----
h_plain = objective.objective_hash(objective.load(refresh=True))
os.environ["MC_COST_FAIL"] = "12345.0"
h_env = objective.objective_hash(objective.load(refresh=True))
del os.environ["MC_COST_FAIL"]
objective.load(refresh=True)
check("ENV 덮어쓴 런은 다른 해시(다른 세대)", h_plain != h_env, "%s vs %s" % (h_plain, h_env))

# ---- 9) Julia 구현이 같은 J 와 같은 해시를 내는가 -----------------------------------
# objective_hash 는 "flat key=value 줄 목록 + sha256" 규약(objective.py/objective.jl 상단 주석
# 참조)이라 JSON 직렬화 바이트 매칭에 기대지 않는다 — 두 언어가 항상 같은 해시를 내야 정상이다.
# M-4: probe 스크립트는 소스 트리 밖의 임시 디렉터리에 쓴다(중간에 죽어도 레포에 잔재가 안
# 남는다). objective.jl 은 @__DIR__ 에 상대적으로 include 되지 않으므로 절대경로를 직접 박는다.
_OBJECTIVE_JL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "objective.jl")
JL = ('include("%s")\n' % _OBJECTIVE_JL) + r'''
using .Objective
cfg = Objective.load()
println("HASH=", Objective.objective_hash(cfg))
println("JFAIL=", Objective.J(complete=false, closed=250, total=300, makespan=500.0, cfg=cfg))
try
    println("JOK=", Objective.J(complete=true, closed=300, total=300,
                                makespan=100.0, energy_J=Float64(cfg["E_ref"]), cfg=cfg))
catch e
    println("JOK=ERROR")
end
'''
jl_dir = tempfile.mkdtemp(prefix="objective_probe_")
jl_path = os.path.join(jl_dir, "_objective_probe.jl")
with open(jl_path, "w") as fh:
    fh.write(JL)
try:
    proc = subprocess.run(["julia", "+lts", "--project=/home/chahj578/Construction_OODlayer",
                           jl_path], capture_output=True, text=True, timeout=600)
    out = proc.stdout
    if proc.returncode != 0:
        print("Julia probe exited with code %d — stderr follows:\n%s" % (proc.returncode, proc.stderr))
    kv = dict(l.split("=", 1) for l in out.strip().splitlines() if "=" in l)

    # M-3: julia 의 returncode/stderr 가 비교 실패시 검사 출력에 남도록 상세문구에 붙인다.
    def jl_detail(msg):
        if proc.returncode != 0 or proc.stderr.strip():
            return msg + "  [julia rc=%d stderr=%r]" % (proc.returncode, proc.stderr.strip()[:2000])
        return msg

    check("Julia/Python 해시 일치", kv.get("HASH") == objective.objective_hash(),
          jl_detail("%s vs %s" % (kv.get("HASH"), objective.objective_hash())))
    py_fail = objective.J(complete=False, closed=250, total=300, makespan=500.0)
    check("Julia/Python 미완주 J 일치",
          abs(float(kv.get("JFAIL", "nan")) - py_fail) < 1e-9,
          jl_detail("%s vs %.9f" % (kv.get("JFAIL"), py_fail)))
    if HAVE_SCALES:
        py_ok = objective.J(complete=True, closed=300, total=300,
                            makespan=100.0, energy_J=CFG["E_ref"])
        check("Julia/Python 완주 J 일치",
              abs(float(kv.get("JOK", "nan")) - py_ok) < 1e-9,
              jl_detail("%s vs %.9f" % (kv.get("JOK"), py_ok)))
finally:
    shutil.rmtree(jl_dir, ignore_errors=True)

print("\n%d/%d 통과" % (0 if FAILED else 1, 1) if False else
      "\n실패 %d건: %s" % (len(FAILED), FAILED) if FAILED else "\n전부 통과")
sys.exit(1 if FAILED else 0)
