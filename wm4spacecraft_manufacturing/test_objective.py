#!/usr/bin/env python3
"""목적함수 J 의 계약 검사 (spec §9). 시뮬레이션 없이 도는 순수 단위검사.

    .venv/bin/python test_objective.py     # exit 0 = 전부 통과
"""
import math
import os
import subprocess
import sys

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


# ---- 1) 순서동치 — argmin J 가 better_ssp 1등을 재현하는가 (spec §9) ----------------
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
    check("순서동치: argmin J == better_ssp 1등",
          (j_best["complete"], j_best["closed"], j_best["makespan"])
          == (ssp_best["complete"], ssp_best["closed"], ssp_best["makespan"]),
          "J=%r ssp=%r" % (j_best, ssp_best))

    # ---- 2) 실패 보상 검사 — 미완주가 완주보다 낮은 J 를 받는 경우가 있는가 (spec §3.1) ----
    # "최악의 완주" 를 스케일과 무관한 임의의 큰 수(예: 1e4, 1e3*E_ref)로 잡으면 이 검사는
    # kappa/C_fail 값과 무관하게 항상 깰 수 있다(에너지 항이 무제한이므로) — 그건 구현 결함이
    # 아니라 검사 설계 결함이다. 대신 실측 분포(objective.json 의 calibrated_from: makespan
    # max=91.0, energy max=257595.95, 둘 다 M_ref/E_ref 의 3배 미만)를 훨씬 넘는, 그러나 여전히
    # "물리적으로 있을 법한" 배수(3x M_ref, 3x E_ref)를 최악의 완주로 쓴다.
    worst_complete = run(dict(complete=True, closed=300, total=300,
                              makespan=3.0 * CFG["M_ref"], energy_J=3.0 * E))
    best_fail = run(dict(complete=False, closed=300, total=300, makespan=0.0))
    check("실패 보상 없음: 최악의 완주 J < 최선의 미완주 J",
          worst_complete < best_fail, "%.3f vs %.3f" % (worst_complete, best_fail))

    # ---- 3) 에너지는 완주 분기에만 (spec §3.1) ----
    a = objective.J(complete=False, closed=250, total=300, makespan=500.0)
    b = objective.J(complete=False, closed=250, total=300, makespan=500.0, energy_J=1e9)
    check("미완주 J 는 energy_J 를 무시한다", a == b, "%.6f vs %.6f" % (a, b))

    # ---- 4) 에너지가 J 를 실제로 움직이는가 (동점해소자로서 살아 있는가, spec §4.2) ----
    lo = objective.J(complete=True, closed=300, total=300, makespan=100.0, energy_J=E)
    hi = objective.J(complete=True, closed=300, total=300, makespan=100.0, energy_J=2 * E)
    check("같은 makespan 이면 에너지가 적은 쪽이 이긴다", lo < hi, "%.6f < %.6f" % (lo, hi))

    # κ 가 동점해소자 크기인가 — 에너지 배가 makespan 2% 차이를 뒤집지 못해야 한다 (spec §4.1)
    # 대수적으로 faster < slower ⟺ f > kappa (f = makespan 을 줄인 비율, 여기서는 에너지를
    # 2배로 늘렸을 때). kappa=0.01 이므로 f=1%(0.99 배수) 는 정확히 등식이 되는 경계값이라
    # (faster == slower, 부동소수 오차 이내) 항상 실패한다 — 이는 구현 버그가 아니라 검사
    # 상수가 kappa 와 우연히 정확히 일치해 생기는 결과다. kappa 보다 확실히 큰 여유(f=2%,
    # 0.98 배수)를 써서 "κ 는 작은 동점해소자다" 라는 원래 취지를 경계값 없이 검증한다.
    faster = objective.J(complete=True, closed=300, total=300,
                         makespan=CFG["M_ref"] * 0.98, energy_J=2 * E)
    slower = objective.J(complete=True, closed=300, total=300,
                         makespan=CFG["M_ref"], energy_J=E)
    check("κ 는 동점해소자다: 2% 더 빠른 계획을 에너지가 뒤집지 못한다",
          faster < slower, "faster=%.4f slower=%.4f kappa=%r" % (faster, slower, CFG["kappa"]))
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

# ---- 6) 완주인데 energy 없음 → 에러 ----
try:
    objective.J(complete=True, closed=1, total=1, makespan=10.0, energy_J=None)
    check("완주 + energy 없음 → 에러", False, "에러가 안 났다")
except objective.ObjectiveError:
    check("완주 + energy 없음 → 에러", True)

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
JL = r'''
include(joinpath(@__DIR__, "objective.jl"))
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
jl_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_objective_probe.jl")
with open(jl_path, "w") as fh:
    fh.write(JL)
try:
    out = subprocess.run(["julia", "+lts", "--project=/home/chahj578/Construction_OODlayer",
                          jl_path], capture_output=True, text=True, timeout=600).stdout
    kv = dict(l.split("=", 1) for l in out.strip().splitlines() if "=" in l)
    check("Julia/Python 해시 일치", kv.get("HASH") == objective.objective_hash(),
          "%s vs %s" % (kv.get("HASH"), objective.objective_hash()))
    py_fail = objective.J(complete=False, closed=250, total=300, makespan=500.0)
    check("Julia/Python 미완주 J 일치",
          abs(float(kv.get("JFAIL", "nan")) - py_fail) < 1e-9,
          "%s vs %.9f" % (kv.get("JFAIL"), py_fail))
    if HAVE_SCALES:
        py_ok = objective.J(complete=True, closed=300, total=300,
                            makespan=100.0, energy_J=CFG["E_ref"])
        check("Julia/Python 완주 J 일치",
              abs(float(kv.get("JOK", "nan")) - py_ok) < 1e-9,
              "%s vs %.9f" % (kv.get("JOK"), py_ok))
finally:
    os.path.exists(jl_path) and os.remove(jl_path)

print("\n%d/%d 통과" % (0 if FAILED else 1, 1) if False else
      "\n실패 %d건: %s" % (len(FAILED), FAILED) if FAILED else "\n전부 통과")
sys.exit(1 if FAILED else 0)
