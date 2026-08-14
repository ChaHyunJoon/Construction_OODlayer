# tools/monitor/dp_lane.jl
# =============================================================================
# **DP 실행 레인** — `DEMO_POLICY=dp` 전용. 라우터에도 대시보드에도 들어가지 않는다.
#
# 왜 라우터의 타깃이 아닌가 (Global Constraint 10 / spec §3.1)
# ----------------------------------------------------------
# DP 의 a* 는 오프라인 표집 + backward induction 의 산물이다. 온라인 결정 시점에 "그 표가 이미
# 있다" 는 것은 **그 사건을 미리 다 굴려봤다** 는 뜻이라, 실행 정책과 같은 줄에 세우면 비교가
# 무의미해진다. 그래서 DP 는 스윕 레인과 FINAL.md 의 천장 행에만 존재한다.
#
# 격자 정의의 단일 진실원은 `dp_oracle/grid_spec.json` 이다
# --------------------------------------------------------
# 버킷팅 규칙을 여기에 새로 만들지 않는다. 파이썬 쪽(`derive_grid.cell_key`)과 **글자 그대로
# 같은 키 문자열**을 내야 하고, 그 동치는 `test_cellkey_parity.py` 가 두 구현에 같은 합성 상태를
# 먹여 기계로 잡는다. (같은 규칙을 두 언어로 적는 것은 그 자체가 위험이므로, 검사 없이 두지
# 않는다.)
#
# 조용한 폴백 금지 (Global Constraint 12)
# --------------------------------------
# a* 가 없으면 canonical 로 떨어지되, **왜 없는지를 네 가지로 구분해** 레코드에 남긴다:
#   not_in_table · infeasible · unreachable · tie_unresolved
# "표에 없다" 와 "동점이라 못 정한다" 는 전혀 다른 사건인데, 뭉뚱그리면 커버리지가 낮은 것을
# 알고리즘이 판단을 보류한 것으로 오독하게 된다.
# =============================================================================

import JSON3

const DP_GRID_PATH = get(ENV, "DP_GRID",
    joinpath(@__DIR__, "..", "..", "wm4spacecraft_manufacturing", "dp_oracle", "grid_spec.json"))
const DP_VALUE_PATH = get(ENV, "DP_VALUE",
    joinpath(@__DIR__, "..", "..", "wm4spacecraft_manufacturing", "dp_oracle", "value.json"))

# 축 순서는 **고정**이다. derive_grid.AXES 와 같아야 하고, dp_solve._bucket() 이 첫 성분
# (prog_b)을 잘라 backward induction 의 버킷으로 쓴다. 바꾸면 조용히 갈린다.
const DP_AXES = ("prog_b", "soc_b", "spares_b", "pend_f", "zone_s", "evt")

const _DP_GRID  = Ref{Any}(nothing)
const _DP_TABLE = Ref{Any}(nothing)

"""격자·값표를 한 번만 읽어 캐시한다. 없으면 `nothing` — **부르는 쪽이 이유를 남긴다.**"""
function dp_grid()
    _DP_GRID[] === nothing || return _DP_GRID[]
    _DP_GRID[] = isfile(DP_GRID_PATH) ? JSON3.read(read(DP_GRID_PATH, String)) : missing
    return _DP_GRID[]
end

function dp_table()
    _DP_TABLE[] === nothing || return _DP_TABLE[]
    _DP_TABLE[] = isfile(DP_VALUE_PATH) ? JSON3.read(read(DP_VALUE_PATH, String)) : missing
    return _DP_TABLE[]
end

"""
    dp_bucket(x, edges) -> Int

오름차순 상단경계 목록에서 `x` 가 드는 칸의 0-기반 인덱스.
마지막 칸은 열려 있다(`x > edges[end]` 이면 `length(edges)-1`).
**`derive_grid.bucket_of()` 와 같은 규칙이어야 한다** — parity 검사가 이를 잡는다.
"""
function dp_bucket(x::Real, edges)
    isfinite(x) || return -1
    for (i, e) in enumerate(edges)
        x <= e && return i - 1
    end
    return length(edges) - 1
end

"""
    dp_cell_key(state::Dict) -> String

형식: `"prog_b=1|soc_b=0|spares_b=2|pend_f=1|zone_s=none|evt=Battery"`.
`derive_grid.cell_key` 와 **글자 그대로 같아야 한다.**
"""
dp_cell_key(state::AbstractDict) =
    join([string(a, "=", get(state, a, nothing)) for a in DP_AXES], "|")

"""
    dp_state(env, truth) -> Dict|nothing

결정 시점 상태 → 격자칸 상태 φ̃. 축 값을 `grid_spec.json` 의 bins 로만 버킷팅한다 —
**새 규칙을 만들지 않는다.**
"""
function dp_state(env, truth)
    g = dp_grid()
    (g === missing || g === nothing) && return nothing
    ax = g["axes"]

    evt = truth isa CB.BatteryTruth ? "Battery" :
          truth isa CB.FaultTruth   ? "Fault"   :
          truth isa CB.ZoneTruth    ? "Zone"    : "Reform"

    # 축 값의 출처는 `ood_features` 하나다 — 스윕 결정 레코드가 찍는 필드와 **같은 함수**라야
    # 오프라인 격자 유도(derive_grid.py)와 온라인 조회가 같은 칸을 가리킨다.
    f = ood_features(env, truth)
    prog   = try Float64(get(f, "progress", NaN))      catch; NaN end
    soc    = try Float64(get(f, "soc", NaN))           catch; NaN end
    spares = try Float64(get(f, "spare_count", NaN))   catch; NaN end
    pend   = try Int(get(f, "agent_pending", -1))      catch; -1 end

    zone_s = "none"
    if truth isa CB.ZoneTruth
        zdg = try CB.zone_diagnosis(env, truth.zone) catch; nothing end
        if zdg !== nothing && zdg.exists
            zone_s = zdg.root_covered > 0 ? "cov" : (zdg.n_nav_blocked > 0 ? "blk" : "none")
        end
    end

    # soc 축은 battery 사건에서만 의미가 있다. 다른 evt 에서 NaN 을 억지로 버킷에 넣지 않고
    # 최상단 칸(= "배터리 문제 아님")으로 둔다 — grid_spec 의 가지치기가 그 조합을 다룬다.
    soc_b = isfinite(soc) ? dp_bucket(soc, ax["soc_b"]["bins"]) :
                            (length(ax["soc_b"]["bins"]) - 1)

    # pend_f 는 **영향받은 로봇**의 일감 수다. zone/reform 사건에는 그 로봇이 없어서 -1 이
    # 찍힌다 — "일감 0" 과 "이 축이 적용되지 않음" 은 다른 상태이므로 섞지 않고 "na" 로 둔다.
    # (derive_grid.state_of 의 편차 D-c 와 **같은 규칙**. 갈리면 parity 검사가 잡는다.)
    pend_f = pend >= 0 ? dp_bucket(pend, ax["pend_f"]["bins"]) : "na"
    return Dict{String,Any}(
        "prog_b"   => isfinite(prog)   ? dp_bucket(prog, ax["prog_b"]["bins"])     : -1,
        "soc_b"    => soc_b,
        "spares_b" => isfinite(spares) ? dp_bucket(spares, ax["spares_b"]["bins"]) : -1,
        "pend_f"   => pend_f,
        "zone_s"   => zone_s,
        "evt"      => evt)
end

"""가지치기 — 정의상 불가능한 칸인가. 규칙은 `grid_spec.json` 의 데이터를 그대로 읽는다."""
function dp_infeasible(state::AbstractDict, g)
    for rule in g["prune"]
        hit = true
        for (k, want) in pairs(rule["cond"])
            got = get(state, String(k), nothing)
            wv = want == "max" ? (length(g["axes"][String(k)]["bins"]) - 1) : want
            if !(got == wv || (got isa Integer && wv isa Integer && got == wv) ||
                 (got isa AbstractString && string(wv) == got))
                hit = false
                break
            end
        end
        hit && return true
    end
    return false
end

"""
    dp_macro(env, truth) -> (macro_name::String, reason::String)

a* 를 못 찾으면 `("", <이유>)`. 호출자가 canonical 로 떨어지되 **이유를 레코드에 남긴다.**
"""
function dp_macro(env, truth)
    g = dp_grid()
    (g === missing || g === nothing) && return ("", "no_grid_spec")
    t = dp_table()
    (t === missing || t === nothing) && return ("", "no_value_table")

    st = dp_state(env, truth)
    st === nothing && return ("", "no_state")
    # "na" 는 결측이 아니라 **정식 칸**이다(편차 D-c). -1 만 미측정이다.
    any(v -> v === -1, [st["prog_b"], st["soc_b"], st["spares_b"]]) &&
        return ("", "state_unmeasurable")
    dp_infeasible(st, g) && return ("", "infeasible")

    key = dp_cell_key(st)
    cells = t["cells"]
    haskey(cells, Symbol(key)) || return ("", "not_in_table")
    cell = cells[Symbol(key)]
    (haskey(cell, :n) && !isempty(cell[:n])) || return ("", "unreachable")
    a = get(cell, :a_star, nothing)
    # 미확정 이유를 **구분해서** 돌려준다. "비교했는데 못 갈랐다"(tie)와 "비교 자체가 없었다"
    # (single_arm)는 전혀 다른 사건이라, 뭉뚱그리면 표집 부족이 알고리즘의 신중함으로 오독된다.
    if a === nothing
        local why = get(cell, :unresolved_reason, nothing)
        return ("", why === nothing ? "tie_unresolved" :
                    (String(why) == "single_arm" ? "single_arm" : "tie_unresolved"))
    end
    return (dp_macro_name(a), "dp_cell=" * key)
end

"매크로 id → 이름. 어휘 단일 진실원은 action_registry.json 이다(리터럴 복붙 금지).
`macros` 는 id 문자열을 키로 갖는 object 다."
function dp_macro_name(id)
    reg = _dp_registry()
    k = Symbol(string(Int(id)))
    haskey(reg["macros"], k) || return ""
    return String(reg["macros"][k]["name"])
end

const _DP_REG = Ref{Any}(nothing)
function _dp_registry()
    _DP_REG[] === nothing || return _DP_REG[]
    p = joinpath(@__DIR__, "..", "..", "wm4spacecraft_manufacturing", "action_registry.json")
    _DP_REG[] = JSON3.read(read(p, String))
    return _DP_REG[]
end
