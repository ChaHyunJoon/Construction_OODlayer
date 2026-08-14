#!/usr/bin/env python3
"""Julia(`dp_lane.jl`) 와 Python(`derive_grid.py`) 이 **같은 칸 키**를 내는지 검사한다.

왜 이 검사가 있어야 하는가
=========================
격자 버킷팅 규칙이 두 언어에 각각 적혀 있다. 오프라인 유도(derive_grid)와 온라인 조회
(dp_lane)가 갈리면 **에러 없이** 서로 다른 칸을 가리키고, 그러면 dp 레인은 언제나
`not_in_table` 을 내면서도 "표에 없는 상태였다" 라고 정직하게 보고한다 — 즉 **버그가
정상 동작처럼 보인다.** 이 저장소가 반복해 겪은 실패 양식(값이 아니라 성능으로만 새는
결함)이라, 규칙을 두 곳에 적는 대가는 반드시 검사로 갚는다.

방법: 합성 상태를 격자 경계 근처로 깔아 양쪽에 먹이고 키 문자열을 글자 그대로 비교한다.
시뮬을 돌리지 않으므로 즉시 끝난다.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))

from derive_grid import bucket_of, cell_key, load_grid   # noqa: E402

FAILS = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + ("   " + detail if detail else ""))
    if not cond:
        FAILS.append(name)


def build_cases(grid):
    """경계 위·아래·사이를 노린다. 버킷 경계는 부등호 하나로 갈리므로 거기서만 갈린다."""
    ax = grid["axes"]
    out = []
    for prog in _probe(ax["prog_b"]["bins"]):
        for soc in _probe(ax["soc_b"]["bins"]):
            for sp in _probe(ax["spares_b"]["bins"]):
                for pend in (-1, 0, 1, 2, 5):
                    out.append(dict(progress=prog, soc=soc, spare_count=sp,
                                    agent_pending=pend))
    return out


def _probe(edges):
    """각 경계에서 정확히·바로 아래·바로 위, 그리고 양 끝 밖."""
    vals = []
    for e in edges:
        vals += [e, e - 1e-9, e + 1e-9]
    vals += [edges[0] - 1.0, edges[-1] + 1.0]
    return vals


def main():
    print("== cell_key parity: Julia dp_lane.jl vs Python derive_grid.py ==")
    grid = load_grid()
    ax = grid["axes"]
    cases = build_cases(grid)
    print("  합성 상태 %d개 (버킷 경계 위/아래/정확히 + 범위 밖)" % len(cases))

    # ---- Python 쪽 키 --------------------------------------------------------------
    py_keys = []
    for c in cases:
        pend = c["agent_pending"]
        st = {
            "prog_b": bucket_of(float(c["progress"]), ax["prog_b"]["bins"]),
            "soc_b": bucket_of(float(c["soc"]), ax["soc_b"]["bins"]),
            "spares_b": bucket_of(float(c["spare_count"]), ax["spares_b"]["bins"]),
            "pend_f": bucket_of(float(pend), ax["pend_f"]["bins"]) if pend >= 0 else "na",
            "zone_s": "none",
            "evt": "Battery",
        }
        py_keys.append(cell_key(st))

    # ---- Julia 쪽 키 ---------------------------------------------------------------
    payload = json.dumps(cases)
    jl = r'''
    import JSON3
    include(joinpath("%s", "tools", "monitor", "dp_lane.jl"))
    cases = JSON3.read(read(stdin, String))
    g = dp_grid()
    ax = g["axes"]
    out = String[]
    for c in cases
        pend = Int(c["agent_pending"])
        st = Dict{String,Any}(
            "prog_b"   => dp_bucket(Float64(c["progress"]), ax["prog_b"]["bins"]),
            "soc_b"    => dp_bucket(Float64(c["soc"]), ax["soc_b"]["bins"]),
            "spares_b" => dp_bucket(Float64(c["spare_count"]), ax["spares_b"]["bins"]),
            "pend_f"   => pend >= 0 ? dp_bucket(pend, ax["pend_f"]["bins"]) : "na",
            "zone_s"   => "none",
            "evt"      => "Battery")
        push!(out, dp_cell_key(st))
    end
    println(JSON3.write(out))
    ''' % REPO.replace("\\", "/")

    proc = subprocess.run(["julia", "+lts", "--project=.", "-e", jl],
                          input=payload, capture_output=True, text=True, cwd=REPO)
    if proc.returncode != 0:
        check("Julia 쪽이 실행된다", False, (proc.stderr or "")[-400:])
        print("\n실패 1개 이상")
        return 1
    jl_keys = json.loads(proc.stdout.strip().splitlines()[-1])

    check("개수가 같다", len(jl_keys) == len(py_keys), "%d vs %d" % (len(jl_keys), len(py_keys)))
    diffs = [(i, p, j) for i, (p, j) in enumerate(zip(py_keys, jl_keys)) if p != j]
    check("모든 합성 상태에서 키가 글자 그대로 같다", not diffs,
          ("첫 불일치 %d건 중 3개: %s" % (len(diffs), diffs[:3])) if diffs else "")

    print("\n%s" % ("전부 통과" if not FAILS else "실패 %d개: %s" % (len(FAILS), FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
