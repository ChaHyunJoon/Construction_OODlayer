# =============================================================================
# gen_oracle_mc.jl -- MDP STEP 2: K-rollout MONTE-CARLO Q labeler.
#   (설계: ../MDP_DESIGN_FROM_SCRATCH.md §7.1, 구현로그 §13)
#
# WHAT THIS REPLACES
# ------------------
# `gen_oracle_fullsim.jl` produces a ONE-SHOT certainty-equivalent label: enact candidate ω,
# run once with NO further failures, take the realized makespan. That is not Q(s,ω). It is a
# myopic value under the assumption "nothing else will ever break", and it is systematically
# wrong exactly where the interesting decisions are — e.g. "should I spend a spare now?" is
# priced as free, because the world where you needed that spare later never gets simulated.
#
# This file estimates the real thing:
#
#     Q(s,ω) = E[ cost(s,ω,τ) + V(s') ]   ≈   (1/K) Σ_k  cost of rollout k
#
# by enacting ω at a FIXED decision state s and then rolling out K times with the STEP-1
# hazard process live, so each rollout samples a different future failure trajectory.
#
# TWO THINGS THAT ARE EASY TO GET WRONG (and are the reason this file exists)
# --------------------------------------------------------------------------
# (1) THE DECISION STATE MUST BE FIXED ACROSS ROLLOUTS.
#     If you let the hazard process also generate the STUDIED event, then rollout k faces a
#     different state s_k, and averaging over k estimates E_s[Q(s,ω)] — an average over a
#     distribution of states — not Q(s,ω) at the state you are labelling. So: the studied fault
#     is injected deterministically (same build seed => same s), and the hazard clocks are
#     ARMED AT THAT INSTANT. Everything before the decision is identical in every rollout and
#     every arm; everything after is the sampled future. That is exactly `s⁺ = f(s,ω)` then roll.
#
# (2) A LEXICOGRAPHIC RANKING CANNOT BE AVERAGED.
#     The 1-shot labeler ranks by (complete? -> closed -> makespan). You cannot take the mean
#     of a lexicographic order over K samples. So we scalarize into the finite-penalty SSP cost
#     of design §6 — and choose the penalty so that at K=1 the argmin REPRODUCES the old
#     lexicographic winner (asserted by `check_order_equivalence`). The penalty `MC_COST_FAIL`
#     is then an explicit MODELLING CHOICE: it sets the exchange rate between "risk of not
#     finishing at all" and "finishing later". Hiding that choice inside a lexicographic rule
#     did not make it go away; it just made it unstated.
#
# COMMON RANDOM NUMBERS (why the CRN work in hazard.jl matters here)
# ------------------------------------------------------------------
# Rollout k uses hazard seed `MC_SEED0 + k` for EVERY candidate. Because hazard.jl draws each
# robot's Exp(1) thresholds and ε_r from a per-robot stream keyed by (seed, robot id), arm A and
# arm B in rollout k give every robot the SAME luck; the only thing that differs is the λ path
# each arm drives it down. So we compare arms PAIRED (d_k = cost_A,k − cost_B,k), which cancels
# the shared trajectory noise. The report prints the achieved variance-reduction factor.
#
# RUN (from the ConstructionBots.jl repo root)
#   julia +lts --project=. wm4spacecraft_manufacturing/oracle/gen_oracle_mc.jl
# ENV
#   MC_K=5              rollouts per candidate
#   MC_ACTIONS="0,1"    candidate macro ids (0 NOOP, 1 Replace, 2 Deprioritize, 3 ForbidZone, 4 ReformTeam)
#   MC_SEED0=1000       hazard seed base; rollout k uses MC_SEED0+k
#   ORACLE_SEED=1       BUILD seed (fixes the decision state s). Different values = different s.
#   MC_ONLY="a:k"       run exactly ONE (action, rollout) unit and append a CSV row (for parallel processes)
#   MC_AGGREGATE=1      read the CSV shards and print/write the summary (no simulation)
#   MTBF_BREAK / MTBF_CELL / MTBF_ZONE / DRAIN_SIGMA    post-decision hazard model
#   HOT_SWAP=1          identity-preserving replacement (default ON — see STEP-1 finding #4)
#   NSPARE=3  RVO=1  SHRINK=200
# =============================================================================
#
# [한국어 요약]
#  이 파일 = "K회 몬테카를로 Q 라벨러". 기존 gen_oracle_fullsim.jl 은 "앞으로 아무 일도 안 일어난다"
#  고 가정하고 1회만 돌려 makespan 을 라벨로 썼다(= certainty-equivalent, Q 가 아님). 여기서는
#  고정된 결정 상태 s 에서 옵션 ω 를 실행한 뒤, STEP-1 의 위험 프로세스를 켠 채 K 번 굴려
#  서로 다른 미래 고장열을 표집하고 평균낸다.
#  반드시 지켜야 할 두 가지: (1) 연구 대상 사건은 모든 rollout 에서 동일해야 한다(안 그러면
#  s 가 rollout 마다 달라져 Q(s,ω) 가 아니라 상태 평균이 된다) → 대상 고장은 결정론적으로 주입하고
#  바로 그 순간에 위험 시계를 켠다. (2) lexicographic 순위는 평균낼 수 없다 → 유한벌점 스칼라
#  비용으로 바꾸되, K=1 에서 기존 순위와 동일해지도록 벌점을 고른다(자동 점검 포함).

import ConstructionBots as CB
import HiGHS, Logging, Random, Graphs
using Printf

include(joinpath(@__DIR__, "ood_mdp_shim.jl"))                        # event_context / valid_actions /
                                                                       # canonical_action / action_to_proposal
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))   # fault_action / battery (world-age)
CB.include(joinpath(pkgdir(CB), "src", "mdp", "mdp.jl"))               # hazard process (STEP 1)

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 60.0, "mip_rel_gap" => 0.05,
    "output_flag" => false, "presolve" => "on")

# ---- configuration ----------------------------------------------------------------------
const K        = parse(Int, get(ENV, "MC_K", "5"))
const ACTIONS  = [parse(Int, strip(s)) for s in split(get(ENV, "MC_ACTIONS", "0,1"), ",") if strip(s) != ""]
const SEED0    = parse(Int, get(ENV, "MC_SEED0", "1000"))
const SEED     = parse(Int, get(ENV, "ORACLE_SEED", "1"))     # BUILD seed = fixes the decision state s
const NSPARE   = parse(Int, get(ENV, "NSPARE", "3"))
const RVO      = get(ENV, "RVO", "1") == "1"
const HOT_SWAP = get(ENV, "HOT_SWAP", "1") == "1"
const SHRINK   = parse(Float64, get(ENV, "SHRINK", "200.0"))
const ONLY     = get(ENV, "MC_ONLY", "")
const AGGONLY  = get(ENV, "MC_AGGREGATE", "0") == "1"
const LOGLVL   = lowercase(get(ENV, "ORACLE_LOG", "warn")) == "info" ? Logging.Info : Logging.Warn

# NO-PROGRESS 상한을 기존 하니스의 30000 에서 크게 줄인다.
# 이유: 30000 스텝의 무진전 = dt=1/40 에서 **750 시뮬초**인데, 이 하니스의 정상 빌드는 겨우
# 13~22 시뮬초다. 즉 정체된 실행 하나가 정상 빌드 35배 길이의 "죽은 시간"을 태우고, 그동안
# 위험 시계는 계속 돌아 사건이 계속 쌓인다(실측: 사후 사건 16건, 벽시계 8분, 미완주).
# SSP 관점에서 정체는 dead-end 이고, dead-end 는 빨리 인식해서 유한벌점을 물리면 된다.
# 부작용으로 벽시계도 대폭 줄어 K-rollout 이 현실적인 비용이 된다.
const NOPROG = parse(Int, get(ENV, "NOPROG", "6000"))    # ≈150 시뮬초 무진전이면 죽은 것으로 판정

# MTBF 는 **이 하니스의 빌드 길이**에 맞춰야 한다(hazard_mdp 데모의 20초짜리 빌드가 아니라).
# 보정 이력(실측):
#   60/45   -> 사후 사건 16건, 함대 전멸, 미완주, 벽시계 8분. 라벨 무의미.
#   150/150 -> 사후 사건 평균 5.3건, 6개 rollout 중 4개가 max_events 상한에 걸림. 여전히 과함.
#   500/500 -> 아래. `expected_hazard_events` 의 하한 추정 대비 실측이 약 2배로 나오는데,
#              그 함수가 마모·SoC 가속·carry 배수를 무시한 하한이라고 명시한 그대로다.
# 목표는 rollout 당 사후 사건 1~2건: 결정을 유의미하게 흔들되 함대를 전멸시키지는 않는 수준.
const HZ = CB.HazardParams(
    mtbf_break_s = parse(Float64, get(ENV, "MTBF_BREAK", "500.0")),
    mtbf_cell_s  = parse(Float64, get(ENV, "MTBF_CELL",  "500.0")),
    mtbf_zone_s  = parse(Float64, get(ENV, "MTBF_ZONE",  "Inf")),
    drain_sigma  = parse(Float64, get(ENV, "DRAIN_SIGMA", "0.15")),
    fire_safe_target = true, fire_require_spare = true,
    fire_obstacle = false, fire_clear = !HOT_SWAP,
    # 정체 중에도 시계는 계속 도는 게 물리적으로 맞지만, 라벨링에서는 폭주를 막아야 한다.
    # 상한에 걸리면 hazard_report().capped=true 로 보고되므로 조용히 잘리지 않는다.
    max_events = parse(Int, get(ENV, "MC_MAX_EVENTS", "12")))

# 1-shot certainty-equivalent 기준선(= 기존 gen_oracle_fullsim.jl 이 만들던 라벨)을 같이 낼지.
# 이게 STEP 2 의 존재 이유를 직접 보여주는 열이다: 위험 프로세스를 끄고 한 번만 돌린 값과
# K 회 평균이 얼마나 다른지, 그리고 1-shot 이 어떤 미래를 통째로 못 본 것인지.
const WANT_REF = get(ENV, "MC_REFERENCE", "1") == "1"

const ACTION_NAME = Dict(0=>"NOOP", 1=>"Replace", 2=>"Deprioritize", 3=>"ForbidZone", 4=>"ReformTeam")
const OUTDIR   = joinpath(@__DIR__, "out")
# MC_SHARD: 병렬 프로세스가 **각자 자기 CSV** 에 쓰게 하는 접미사. 같은 파일에 여러 프로세스가
# append 하면 Windows 에서 줄이 섞일 수 있어(짧은 줄이라 대개 괜찮지만 보장은 없다) 아예 분리한다.
# 집계(`read_units`)는 out/ 의 `oracle_mc_units_s<SEED>*.csv` 를 전부 읽어 합친다.
const SHARD    = get(ENV, "MC_SHARD", "")
const UNITCSV  = joinpath(OUTDIR, "oracle_mc_units_s$(SEED)$(isempty(SHARD) ? "" : "_" * SHARD).csv")
const SUMJSON  = joinpath(OUTDIR, "oracle_mc_summary_s$(SEED).json")

# ---- the finite-penalty SSP cost (design §6) --------------------------------------------
# 완주하면 실현 makespan 이 곧 비용. 완주 못 하면 큰 유한벌점 + 못 닫은 노드 수 벌점(부분 점수),
# 그리고 아주 작은 가중치의 makespan 으로 동점을 깬다. 이 세 항의 크기 순서가 곧 lexicographic
# 순서(완주 > 닫힌 노드 수 > makespan)를 스칼라로 옮긴 것이다.
# 목적함수 상수의 단일 진실원 — 리터럴 복붙 금지(spec §5). ENV 덮어쓰기(MC_COST_FAIL /
# MC_COST_UNCLOSED)는 Objective.load 안에서 처리되고, 덮어쓴 런은 objective_hash 가 달라져
# **다른 세대**로 취급된다(§7). 완주 분기의 에너지 항도 여기서 같이 들어온다(§3.1).
include(joinpath(@__DIR__, "..", "objective.jl"))
using .Objective

const OBJ_CFG  = Objective.load()
const OBJ_HASH = Objective.objective_hash(OBJ_CFG)
# 아래 세 상수는 하위호환용 별칭이다(로그·요약 meta 가 이름으로 읽는다). 값의 출처는 objective.json.
const COST_FAIL     = Float64(OBJ_CFG["C_fail"])
const COST_UNCLOSED = Float64(OBJ_CFG["C_unclosed"])
const COST_TIE_EPS  = Float64(OBJ_CFG["tie_eps"])

# 플래너(greedy/MILP)의 목적함수 가중치도 같은 objective.json 에서 심는다 (spec §4, §5) —
# 라벨을 매기는 J 와 그 라벨을 만들어 낸 플래너가 같은 κ 를 쓰게 하는 자리다.
# ENERGY_OBJECTIVE=0 이면 끈다(구세대 재현용 탈출구 — 껐다는 사실이 로그에 남는다).
if get(ENV, "ENERGY_OBJECTIVE", "1") == "1"
    let w = CB.init_objective_weights!()
        println(">>> objective weights: κ=$(w.kappa) w_g=$(w.w_g)")
    end
else
    println(">>> objective weights: DISABLED (ENERGY_OBJECTIVE=0) — 구세대 동작")
end

# 목적함수 J (spec §3). 완주 분기에만 에너지가 들어간다.
# 주의: r 에 energy_J 가 없거나 NaN 이면(구세대 레코드/배터리 레이어 OFF) Objective.J 가
# 던진다 — 조용히 0 이 되지 않는다(§5, §7).
scalar_cost(r) = Objective.J(complete = r.complete, closed = r.closed, total = r.total,
                             makespan = r.makespan,
                             energy_J = hasproperty(r, :energy_J) ? r.energy_J : nothing,
                             cfg = OBJ_CFG)

# --- 기존(legacy) 사전식 비교 -------------------------------------------------------------
# gen_oracle_fullsim.jl 이 쓰던 규칙 그대로. 참조·호환성 확인용으로만 남긴다.
better(a, b) = a.complete != b.complete ? a.complete :
               a.closed   != b.closed   ? a.closed > b.closed :
               a.makespan < b.makespan

# --- SSP 로 교정한 사전식 비교 (이게 정답 규칙) ---------------------------------------------
# legacy 규칙과 딱 한 군데에서 다르다: **둘 다 완주한 경우 closed 수를 보지 않는다.**
#
# 왜 고쳐야 하는가: 이 하니스에서 `project_complete == true` 인데도 closed < total 이다
# (오라클 로그 실측: CONTROL(nofault) YES 291/313). 목표에 도달한 뒤 남아 있는 스케줄 노드는
# 미완의 "작업"이 아니라 장부(유휴 로봇의 종단 노드 등)다. legacy 규칙은 그 장부 노드를 몇 개
# 더 닫았다는 이유로 **더 느린 실행을 더 낫다고 판정**할 수 있다.
# SSP 에서 흡수상태(조립 완료)에 도달하면 비용은 경과시간뿐이므로, 완주끼리는 makespan 만 본다.
#
# [2026-08-13] `better_ssp` 는 **에너지를 모른다**. 목적함수 J 는 완주 분기에 w_E·energy_J 를
# 더하므로(spec §3.1), 완주끼리는 `scalar_cost` 가 `better_ssp` 와 **의도적으로 갈릴 수 있다**.
# 따라서 "scalar_cost 는 better_ssp 와 동치" 라는 옛 주장은 더 이상 참이 아니다. 실제 불변식은
# `check_order_equivalence` 의 독스트링에 적혀 있다 — 그쪽이 검사하는 것이 진짜 계약이다.
better_ssp(a, b) = a.complete != b.complete ? a.complete :
                   a.complete               ? a.makespan < b.makespan :
                   a.closed != b.closed     ? a.closed > b.closed :
                   a.makespan < b.makespan

_same_outcome(a, b) = a.complete == b.complete && a.closed == b.closed &&
                      isequal(a.makespan, b.makespan)   # NaN 대비: == 가 아니라 isequal

_energy_of(r) = hasproperty(r, :energy_J) ? Float64(r.energy_J) : NaN

"""
    energy_budget(a, b) -> Float64

완주 두 런 사이에서 **에너지가 순위를 뒤집어도 되는 makespan 차이의 상한**.
`w_E·|ΔE| = κ·M_ref·|ΔE| / E_ref` (spec §3.1, §4.1). κ 가 곧 "에너지 1 단위를 몇 초로 살
것인가"의 환율이므로, 이 예산 안의 makespan 역전은 **결함이 아니라 설계된 동작**이다.
"""
energy_budget(a, b) = Objective.energy_weight(OBJ_CFG) * abs(_energy_of(a) - _energy_of(b))

"두 런에서 scalar_cost 가 better_ssp 와 갈리는 것이 **에너지 항으로 설명되는가**."
function explained_by_energy(a, b)
    (a.complete && b.complete) || return false      # 에너지는 완주 분기에만 들어간다(§3.1)
    e = energy_budget(a, b)
    isfinite(e) || return false
    return abs(Float64(a.makespan) - Float64(b.makespan)) <= e + 1e-12
end

"""
    check_order_equivalence(results) -> Bool

**검사하는 실제 불변식** (spec §9. 2026-08-13 에 정정 — 예전의 "전역 순서동치" 주장은
에너지 항이 생긴 뒤로 틀린 명제가 됐다):

  1. 완주/미완주 **경계**에서, 그리고 **미완주끼리는** `scalar_cost` 의 순위가 `better_ssp` 와
     정확히 같아야 한다. 여기서 갈리면 C_fail / C_unclosed 가 문제 규모에 비해 작다는 뜻이다.
  2. **완주끼리는** `better_ssp`(makespan 만 봄)와 갈릴 수 있다 — 단, makespan 차이가
     `energy_budget = w_E·|ΔE|` **안**일 때만. 예산 안의 역전은 κ 가 사기로 한 거래이므로
     정상이고, 예산 **밖**의 역전은 κ 가 과대하다는 뜻이다.

옛 코드는 이 구분 없이 argmin 하나만 비교해서, **정당한 에너지 역전**에도
"raise MC_COST_FAIL" 이라고 경고했다 — 그 조치로는 절대 고쳐지지 않는 경고였다
(실측 규모: energy 2.1e5~4.4e5 J, w_E=2.56e-6 → 에너지 항 0.53~1.12 s vs 완주 makespan 19~31 s).

legacy `better` 와 갈리는 경우도 함께 알려준다 — 숨기면 예전 덤프와 라벨이 왜 다른지
아무도 모르게 된다.
"""
function check_order_equivalence(results)
    isempty(results) && return true
    rs = collect(results)

    viol_bound = Tuple{Any,Any}[]   # 경계/미완주 위반 -> C_fail·C_unclosed 문제
    # viol_energy 는 **현재의 J 형태에서는 증명 가능하게 도달 불가**다. 완주 두 런에 대해
    #     J(a) - J(b) = (mk_a - mk_b) + w_E·(E_a - E_b)
    # 이므로 `better_ssp`(= mk_a < mk_b)와 부호가 갈리려면 에너지 항이 makespan 차를 덮어야 하고,
    # 그것은 곧 |Δmk| ≤ w_E·|ΔE| = energy_budget 이다 — `explained_by_energy` 의 조건과 항등적으로
    # 같다. (2026-08-13 리뷰 실측: 무작위 쌍 20만 개 -> 불일치 1677 건, 설명 안 되는 것 0 건.)
    #
    # 그래도 지운다면 그건 "지금의 J 형태"에만 기대는 것이다. 다음 중 하나라도 생기면 도달 가능해진다:
    #   - 완주 분기가 makespan 에 선형이 아니게 되거나(예: 로그·포화 항),
    #   - w_E 가 두 런에서 다른 값이 되거나(런별 κ·스케일),
    #   - better_ssp 가 makespan 외의 축을 다시 보게 되거나,
    #   - energy_budget 이 |ΔE| 가 아닌 다른 양으로 계산되면.
    # 방어선으로 남긴다 — 계약을 코드로 적어 두는 값이 죽은 분기 한 개 값보다 크다.
    viol_energy = Tuple{Any,Any}[]  # 완주끼리, 예산 **밖** 역전 -> kappa 문제 (현재 J 에서는 도달 불가)
    n_flip = 0                      # 예산 안의 정당한 에너지 역전(정상)
    for i in 1:length(rs), j in (i + 1):length(rs)
        a, b = rs[i], rs[j]
        _same_outcome(a, b) && continue      # complete/closed/makespan 이 같으면 에너지만 남는다
        better_ssp(a, b) == (scalar_cost(a) < scalar_cost(b)) && continue
        if a.complete && b.complete
            explained_by_energy(a, b) ? (n_flip += 1) : push!(viol_energy, (a, b))
        else
            push!(viol_bound, (a, b))
        end
    end

    isempty(viol_bound) || @warn "[MC] 완주/미완주 경계(또는 미완주끼리)에서 scalar cost 가 " *
        "better_ssp 와 갈린다 — 실패 벌점이 문제 규모에 비해 작다. " *
        "조치: MC_COST_FAIL / MC_COST_UNCLOSED 를 올리거나 objective.json 의 C_fail·C_unclosed 를 " *
        "키운다(값을 바꾸면 objective_hash 가 갈려 다른 세대가 된다)." n_pairs = length(viol_bound) example = viol_bound[1] objective_hash = OBJ_HASH

    isempty(viol_energy) || @warn "[MC] 완주끼리 scalar cost 가 better_ssp 와 갈리는데 그 폭이 " *
        "에너지 예산(w_E·|ΔE|)을 넘는다 — kappa 가 과대하다는 뜻이다(MC_COST_FAIL 로는 고쳐지지 않는다). " *
        "조치: objective.json 의 kappa 를 낮추거나, 이 역전이 의도라면 better_ssp 기준 자체를 " *
        "에너지를 아는 규칙으로 고친다." n_pairs = length(viol_energy) example = viol_energy[1] w_E = Objective.energy_weight(OBJ_CFG) objective_hash = OBJ_HASH

    n_flip > 0 && @info "[MC] 에너지가 makespan 순위를 뒤집은 쌍 $(n_flip)개 — 예산 안이라 정상이다 " *
        "(spec §3.1/§4.1: κ 가 정한 환율만큼만 뒤집힌다)."

    ssp_best = sort(rs, lt = (a, b) -> better_ssp(a, b))[1]
    leg_best = sort(rs, lt = (a, b) -> better(a, b))[1]
    _same_outcome(leg_best, ssp_best) ||
        @info "[MC] legacy `better` 와 정답이 갈림(둘 다 완주인데 closed 수가 다른 경우). " *
              "SSP 기준이 맞다 — 완주 후 남은 노드는 작업이 아니라 장부." legacy = leg_best ssp = ssp_best
    return isempty(viol_bound) && isempty(viol_energy)
end

# ---- tiny stats (Statistics 를 Project 의존성으로 끌어들이지 않으려고 직접 계산) ------------
_mean(v) = isempty(v) ? NaN : sum(v) / length(v)
function _std(v)
    length(v) < 2 && return NaN
    m = _mean(v); return sqrt(sum((x - m)^2 for x in v) / (length(v) - 1))
end
_se(v) = length(v) < 2 ? NaN : _std(v) / sqrt(length(v))

# ---- producers (gen_oracle_fullsim.jl 과 동일한 공정성 불변식) ------------------------------
const SEEN     = Ref{Any}(nothing)
const N_EVENTS = Ref(0)

# 후보 액션 a 를 "연구 대상 fault 이벤트에서만" 내고, 그 외 모든 배경 이벤트(위험 프로세스가
# 만든 사후 고장 포함)에는 후보와 무관하게 항상 canonical 대응을 준다.
# 이게 공정성 불변식이다: 팔 사이에 다른 것은 오직 "연구 대상 사건에서의 결정" 하나뿐이어야 한다.
# 사후 사건까지 후보 액션으로 덮어버리면 우리가 재는 것이 Q(s,ω) 가 아니라 "그 액션만 반복하는
# 정책의 가치"가 되어버린다.
# =========================================================================================
#  STEP 6 : 확장 행동공간 (원시 파라미터까지 포함) — V^macro − V* 의 gap 측정용
# -----------------------------------------------------------------------------------------
#  설계 §4.4: 옵션(macro)으로 행동공간을 제한한 대가를 **숨기지 말고 재라**.
#  A_macro ⊂ A_raw 이므로 V^macro ≥ V*. 그 차이가 곧 "옵션 근사의 손실" 이다.
#  여기서는 원시공간 전체(배정 조합)를 뒤지는 대신, 각 옵션의 **연속 파라미터**를 열어 A 를 넓힌다.
#  이게 정직한 최소 스코프다 — 배정 조합 전수탐색은 이 규모에서 불가능하므로, 측정된 gap 은
#  **진짜 gap 의 하한(lower bound)** 이라고 보고해야 한다.
#
#  arm id 규약: 0~4 = 기존 5개 macro(정확히 동일). 10번대 = Replace(after=…), 20번대 = Deprioritize(factor=…)
const EXT_ARMS = Dict(
    10 => (:replace, 0.0),   11 => (:replace, 5.0),   12 => (:replace, 15.0),
    20 => (:deprio, 10.0),   21 => (:deprio, 50.0),   22 => (:deprio, 200.0),
)
EXT_NAME = Dict(10=>"Replace@0", 11=>"Replace@5", 12=>"Replace@15",
                20=>"Deprio×10", 21=>"Deprio×50", 22=>"Deprio×200")
arm_name(a::Int) = get(ACTION_NAME, a, get(EXT_NAME, a, "arm$a"))

"확장 arm 을 실제 DSL 제안으로. 기존 macro(0~4)면 기존 경로를 그대로 탄다."
function arm_to_proposal(ctx, a::Int)
    haskey(EXT_ARMS, a) || return action_to_proposal(ctx, a)
    kindsym, p = EXT_ARMS[a]
    ctx.agent === nothing && return nothing
    cs = kindsym === :replace ? CB.ConstraintSpec[CB.ReplaceAgent(ctx.agent, p)] :
                                CB.ConstraintSpec[CB.DeprioritizeAgent(ctx.agent, p)]
    return CB.RespecProposal(cs, "ext arm $a", String(ctx.source))
end

mc_prod(a::Int) = (env, ev) -> begin
    ctx = event_context(env, ev)
    N_EVENTS[] += 1
    if ctx.type === :fault && SEEN[] === nothing
        SEEN[] = (type = String(ctx.type), agent = string(ctx.agent), valid = valid_actions(ctx))
        a == 0 && return nothing                       # 의도적 NOOP
        return arm_to_proposal(ctx, a)
    end
    return action_to_proposal(ctx, canonical_action(ctx))
end

function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end),
        nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
end

# ---- the studied event + hazard arming ---------------------------------------------------
"""
    schedule_studied_fault!(hz_seed)

Inject ONE deterministic breakdown (the decision state `s`) and ARM the hazard process at that
exact instant with `hz_seed`. Everything before this point is identical across rollouts and
arms; everything after is the sampled future. Returns nothing.
"""
# 결정 상태 s 를 만드는 고장 1건을 결정론적으로 주입하고, **바로 그 순간에** 위험 프로세스를 켠다.
# 이 순서가 핵심 — 켜는 시점이 앞이면 결정 이전 궤적까지 rollout 마다 달라져 s 가 고정되지 않는다.
function schedule_studied_fault!(hz_seed::Union{Nothing,Int})
    fired = Ref(false)
    tf = CB.fault_action(; safe = true, obstacle = false, clear = !HOT_SWAP)
    act = function (env)
        fired[] && return nothing
        nl = tf(env)
        nl === nothing && return nothing
        fired[] = true
        if hz_seed !== nothing
            CB.enable_hazard!(env; params = HZ, seed = hz_seed)
            @info "[MC] hazard armed at the decision point (seed=$hz_seed)"
        end
        return nl
    end
    for c in (12, 20, 30, 45, 60); CB.schedule_ood_at_closed!(c, act); end
    return nothing
end

# ---- one full simulation ------------------------------------------------------------------
"""
    run_one(prod; inject=true, hz_seed=nothing) -> NamedTuple

One production full-sim with `prod` on the respec seam. `hz_seed=nothing` disables the hazard
process entirely (that reproduces the OLD 1-shot certainty-equivalent label, which is how the
K=1/no-hazard reference column is produced).
"""
function run_one(prod; inject::Bool = true, hz_seed::Union{Nothing,Int} = nothing)
    SEEN[] = nothing; N_EVENTS[] = 0
    CB.RESPEC_ENABLED[] = true
    try CB.disable_hazard!() catch end          # 이전 실행 잔여 상태 + 스텝 훅 원복
    for f in (:clear_ood_schedule!, :clear_restriction_zones!, :clear_spare_pools!,
              :clear_faulted_robots!, :clear_recovery_spares!, :clear_ood_truth_log!,
              :clear_wedge_edges!, :clear_stalled_robots!)
        try getproperty(CB, f)() catch end
    end
    try CB.set_reform_interval!(400) catch end
    HOT_SWAP && CB.set_hot_swap!(enabled = true, mode = :via_depot)
    CB.set_respec_producer!(prod)

    # 배터리 계층은 스텝 1에 켠다(SoC 결합 λ 와 셀 위험에 필요). 위험 프로세스가 켜지기 전까지
    # 방전 배수는 1.0 이므로 결정 이전 궤적은 완전히 결정론적이다 — s 고정의 전제.
    CB.schedule_ood!(1, function (env)
        CB.enable_battery!(env; params = CB.demo_battery_params(shrink = SHRINK))
        CB.set_battery_penalty!(gain = 6.0, soc_target = 0.5, hard_mult = 1.0e3)
        return nothing
    end)
    inject && schedule_studied_fault!(hz_seed)

    # 스택은 **판마다 통째로** 잡히므로 N 병렬이면 N×이 값이 그대로 메모리다.
    # 실측(2026-08-01 00:25): 데이터셋 생성 6병렬 × 1GB 가 OutOfMemoryError 로 3개 샤드를 죽였다.
    # 2GB 하드코딩을 그대로 두면 STEP 6 을 3병렬로 띄우는 순간 6GB 라 같은 식으로 터진다.
    # 1GB 는 동일 시뮬에서 StackOverflow 없이 돈 것이 확인된 값이라(죽은 원인은 스택 깊이가 아니라
    # 전체 메모리였다) 그대로 기본값으로 쓴다. 더 낮추려면 반드시 1인스턴스 스모크로 확인할 것.
    res = run_with_stack(parse(Int, get(ENV, "MC_STACK", "1000000000"))) do
        CB.run_lego_demo(; ldraw_file = "tractor.mpd", num_robots = 10, assignment_mode = :greedy,
            milp_optimizer = :highs, optimizer_time_limit = 60, log_level = LOGLVL,
            max_num_iters_no_progress = NOPROG, rvo_flag = RVO, tangent_bug_flag = RVO,
            dispersion_flag = RVO, n_spare_per_pool = NSPARE, save_animation = false,
            open_animation_at_end = false, write_results = false, overwrite_results = true,
            return_env_before_sim = false, rng = Random.MersenneTwister(SEED))
    end
    hz = CB.hazard_report()
    try CB.disable_hazard!() catch end
    CB.clear_respec_producer!(); CB.RESPEC_ENABLED[] = false

    env   = res isa Tuple ? res[1] : res
    stats = res isa Tuple ? res[2] : Dict()
    return (complete = CB.project_complete(env),
            closed    = length(env.cache.closed_set),
            total     = length(CB.get_nodes(env.sched)),
            makespan  = try Float64(get(stats, :Makespan, NaN)) catch; NaN end,
            # 실현 구동에너지[J] — 목적함수 J 의 완주 분기가 쓰는 값(objective.json, spec §3).
            # 배터리 레이어가 꺼져 있거나 report 가 실패하면 NaN(J 계산 시 에러로 드러난다).
            energy_J  = (try
                    local _fl = CB.BATTERY_FLEET[]
                    _fl === nothing ? NaN : Float64(CB.battery_report(_fl).total_energy_J)
                catch e
                    @warn "[MC] battery_report 실패 — energy_J=NaN" exception = e
                    NaN
                end),
            seen      = SEEN[], n_events = N_EVENTS[],
            # 사후(post-decision) 고장 수 — rollout 들이 정말 서로 다른 미래를 겪었는지의 증거
            hz_break = hz.n_break, hz_cell = hz.n_cell, hz_zone = hz.n_zone,
            hz_pending_break = hz.n_break_pending, hz_capped = hz.capped,
            hz_sim_s = hz.t)
end

# ---- CSV shard I/O (parallel units) -------------------------------------------------------
# objective_hash 는 **cost 열이 어느 목적함수로 계산됐는지**를 행에 박는다(spec §7).
# 이게 없으면 다른 J 로 만든 샤드가 read_units() 에서 조용히 한 Q̂ 로 평균된다 — 이 저장소가
# 실제로 겪은 "두 세대 혼입" 결함 그대로다.
const CSV_HEADER = "action,rollout,hz_seed,complete,closed,total,makespan,cost,hz_break,hz_cell,hz_zone,hz_pending,hz_capped,hz_sim_s,agent,energy_J,objective_hash"
function append_unit!(a::Int, k::Int, hz_seed::Int, r)
    mkpath(OUTDIR)
    isfile(UNITCSV) || open(io -> println(io, CSV_HEADER), UNITCSV, "w")
    open(UNITCSV, "a") do io
        # energy_J 는 makespan 과 같은 컨벤션으로 미완주/비유한 값을 -1.0 로 센티넬한다(CSV 는
        # 헤더 이름으로 읽는 소비처(step6_gap.py)와 위치로 읽는 read_units() 양쪽에 안전해야 한다).
        @printf(io, "%d,%d,%d,%s,%d,%d,%.4f,%.4f,%d,%d,%d,%d,%s,%.2f,%s,%.4f,%s\n",
                a, k, hz_seed, r.complete ? "true" : "false", r.closed, r.total,
                isfinite(r.makespan) ? r.makespan : -1.0, scalar_cost(r),
                r.hz_break, r.hz_cell, r.hz_zone, r.hz_pending_break,
                r.hz_capped ? "true" : "false", r.hz_sim_s,
                r.seen === nothing ? "none" : r.seen.agent,
                isfinite(r.energy_J) ? r.energy_J : -1.0, OBJ_HASH)
    end
end

"이 build seed 의 모든 샤드 CSV 경로(병렬 프로세스가 각자 쓴 것들)."
unit_csv_files() = isdir(OUTDIR) ?
    sort([joinpath(OUTDIR, f) for f in readdir(OUTDIR)
          if startswith(f, "oracle_mc_units_s$(SEED)") && endswith(f, ".csv")]) : String[]

function read_units()
    files = unit_csv_files()
    isempty(files) && return NamedTuple[]
    rows = NamedTuple[]
    stale = Dict{String,Set{String}}()   # 파일 -> 그 파일에서 본 (현행이 아닌) objective_hash 들
    for fp in files, line in eachline(fp)
        startswith(strip(line), "action,") && continue   # 각 샤드의 헤더 줄 건너뜀
        f = split(strip(line), ",")
        length(f) < 15 && continue
        # f[17](objective_hash) 는 이 필드가 추가되기 전 샤드에는 없다. 없거나 현행과 다르면
        # 그 행의 cost 열은 **다른 목적함수로 계산된 값**이다 — 아래에서 시끄럽게 멈춘다(§7).
        h = length(f) >= 17 ? String(f[17]) : "<none>"
        h == OBJ_HASH || push!(get!(stale, fp, Set{String}()), h)
        try
            # f[16](energy_J) 는 이 필드가 추가되기 전 샤드 CSV 에는 없다 — 있으면 파싱, 없으면 NaN.
            push!(rows, (action = parse(Int, f[1]), rollout = parse(Int, f[2]),
                         hz_seed = parse(Int, f[3]), complete = f[4] == "true",
                         closed = parse(Int, f[5]), total = parse(Int, f[6]),
                         makespan = parse(Float64, f[7]), cost = parse(Float64, f[8]),
                         hz_break = parse(Int, f[9]), hz_cell = parse(Int, f[10]),
                         hz_zone = parse(Int, f[11]), hz_pending = parse(Int, f[12]),
                         hz_capped = f[13] == "true", hz_sim_s = parse(Float64, f[14]),
                         agent = f[15],
                         energy_J = length(f) >= 16 ? parse(Float64, f[16]) : NaN,
                         objective_hash = h))
        catch; end
    end
    # 세대 혼입은 조용히 넘어가지 않는다(spec §7). cost 열끼리 평균내는 것이 이 함수의 전부인데,
    # 서로 다른 J 로 계산된 cost 를 섞으면 Q̂ 가 아무것도 뜻하지 않게 된다.
    stale_lines = ["  " * fp * " : objective_hash=" * join(sort(collect(hs)), ", ")
                   for (fp, hs) in sort(collect(stale), by = first)]
    # 관측된 값이 실제 해시인지 '열 자체가 없음'인지에 따라 원인이 다르므로 그때만 설명한다.
    saw_none = any(h -> h == "<none>", Iterators.flatten(values(stale)))
    isempty(stale) || throw(Objective.ObjectiveError(
        "[MC] 이 샤드 CSV 들은 현행 목적함수(objective_hash=$OBJ_HASH)로 계산된 cost 가 아니다:\n" *
        join(stale_lines, "\n") * "\n" *
        (saw_none ? "'<none>' = objective_hash 열이 생기기 전의 **구세대** 샤드(에너지 항 없는 J).\n" : "") *
        "조치: (1) 그 샤드를 다른 곳으로 옮기거나 지우고 현행 J 로 유닛을 다시 돌린다, 또는\n" *
        "      (2) 그 세대를 재현하려면 당시의 ENV(MC_COST_FAIL/MC_COST_UNCLOSED)와 objective.json 을 되돌린다.\n" *
        "다른 J 로 계산된 cost 를 현행 cost 와 섞어 평균내지 않는다."))
    # (action, rollout) 중복 제거 — 같은 유닛을 재실행했거나 샤드가 겹치면 그대로 두 번 세어져
    # Q̂ 가 조용히 틀어진다. 나중 것을 채택한다.
    seen = Dict{Tuple{Int,Int},NamedTuple}()
    for r in rows; seen[(r.action, r.rollout)] = r; end
    n_dup = length(rows) - length(seen)
    n_dup > 0 && @info "[MC] 중복 유닛 $(n_dup)개 제거(같은 action/rollout 재실행분)."
    return sort(collect(values(seen)), by = r -> (r.action, r.rollout))
end

# ---- minimal JSON writer (gen_oracle_fullsim.jl 과 동일) ------------------------------------
jesc(s) = replace(replace(String(s), "\\" => "\\\\"), "\"" => "\\\"")
jval(x) = x isa Bool ? (x ? "true" : "false") :
          x isa AbstractString ? "\"$(jesc(x))\"" :
          x isa Real ? (isfinite(x) ? string(x) : "\"$(x)\"") : "\"$(x)\""
jobj(nt) = "{" * join(["\"$(k)\":$(jval(getproperty(nt, k)))" for k in propertynames(nt)], ",") * "}"
function write_json(path, meta, rows)
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, "{"); println(io, "  \"meta\": $(jobj(meta)),"); println(io, "  \"candidates\": [")
        for (i, c) in enumerate(rows); println(io, "    ", jobj(c), i < length(rows) ? "," : ""); end
        println(io, "  ]"); println(io, "}")
    end
end

# ---- aggregation: Q̂, SE, paired differences, tie detection ---------------------------------
"""
    aggregate(rows) -> (summary_rows, meta)

Per candidate: Q̂ = mean cost, unpaired SE, and — vs the best candidate — the PAIRED difference
`d_k = cost_a,k − cost_best,k` with its own SE. A candidate is declared TIED with the best when
`|Δ| ≤ 1.96·SE_paired`: reporting a tie as a win is the single easiest way to manufacture fake
decision quality, so ties are labelled, not broken.
"""
# 후보별 Q̂ = 평균 비용, 표준오차, 그리고 최선 후보와의 **짝지은 차이**. |Δ| ≤ 1.96·SE_paired 면
# 동점으로 표시한다. 동점을 승리로 보고하는 것이 가짜 결정품질을 만드는 가장 쉬운 방법이라,
# 동점은 깨지 말고 라벨을 붙인다.
function aggregate(all_rows)
    # rollout 0 = 1-shot 기준선(위험 프로세스 끔). MC 평균에 섞으면 안 되므로 분리한다.
    rows = [r for r in all_rows if r.rollout > 0]
    # MC rollout 이 하나도 없으면(기준선만 있는 경우) 빈 결과를 돌려준다. 반환 개수는 정상 경로와
    # 반드시 같아야 한다 — 2-튜플로 돌려주면 호출부가 BoundsError 로 죽는다.
    isempty(rows) && return NamedTuple[], (best_action = -1, best_name = "none", best_Q = NaN,
        K = 0, n_rows = 0, build_seed = SEED, seed0 = SEED0, mtbf_break = HZ.mtbf_break_s,
        mtbf_cell = HZ.mtbf_cell_s, hot_swap = HOT_SWAP, rvo = RVO, spares = 4 * NSPARE,
        cost_fail = COST_FAIL, cost_unclosed = COST_UNCLOSED, objective_hash = OBJ_HASH,
        crn_variance_reduction = NaN,
        ref_best_action = -1, ref_agrees_with_mc = false),
        [r for r in all_rows if r.rollout == 0]
    acts = sort(unique(r.action for r in rows))
    costs = Dict(a => Float64[] for a in acts)
    byk   = Dict(a => Dict{Int,Float64}() for a in acts)
    for r in rows
        push!(costs[r.action], r.cost); byk[r.action][r.rollout] = r.cost
    end
    Q  = Dict(a => _mean(costs[a]) for a in acts)
    best = acts[argmin([Q[a] for a in acts])]

    out = NamedTuple[]
    vr_factors = Float64[]
    for a in acts
        # 두 팔 모두에서 완료된 rollout 만 짝지어 비교(공통 k 집합)
        ks = sort(collect(intersect(keys(byk[a]), keys(byk[best]))))
        d  = [byk[a][k] - byk[best][k] for k in ks]
        se_paired   = _se(d)
        se_unpaired = sqrt(max(0.0, _se(costs[a])^2 + _se(costs[best])^2))
        isfinite(se_paired) && se_paired > 0 && isfinite(se_unpaired) &&
            push!(vr_factors, se_unpaired / se_paired)
        Δ = _mean(d)
        tied = a != best && isfinite(se_paired) && abs(Δ) <= 1.96 * se_paired
        n_complete = count(r -> r.action == a && r.complete, rows)
        push!(out, (action = a, name = arm_name(a), K = length(costs[a]),
                    Q = Q[a], se = _se(costs[a]),
                    delta_vs_best = Δ, se_paired = se_paired,
                    tied_with_best = tied, is_best = (a == best),
                    p_complete = n_complete / max(1, length(costs[a])),
                    mean_hz_events = _mean([Float64(r.hz_break + r.hz_cell + r.hz_zone)
                                            for r in rows if r.action == a]),
                    # 사건 상한에 걸린 rollout 수 — >0 이면 그 rollout 의 미래가 잘린 것이라
                    # 라벨이 낙관적으로 편향된다. 조용히 넘어가면 안 되므로 명시적으로 센다.
                    n_capped = count(r -> r.action == a && r.hz_capped, rows)))
    end
    # --- 1-shot 기준선과의 비교 ---------------------------------------------------------
    refs = [r for r in all_rows if r.rollout == 0]
    ref_best = -1
    if !isempty(refs)
        ref_best = refs[argmin([r.cost for r in refs])].action
    end
    # K 는 ENV 기본값(`MC_K`)이 아니라 **실제 데이터에 있는 rollout 수**로 보고해야 한다.
    # 집계 모드는 MC_K 를 안 주고 부르는 게 보통이라, ENV 값을 쓰면 헤더에 엉뚱한 K 가 찍힌다.
    K_actual = maximum(length(costs[a]) for a in acts)
    meta = (best_action = best, best_name = arm_name(best), best_Q = Q[best],
            K = K_actual, n_rows = length(rows), build_seed = SEED, seed0 = SEED0,
            mtbf_break = HZ.mtbf_break_s, mtbf_cell = HZ.mtbf_cell_s,
            hot_swap = HOT_SWAP, rvo = RVO, spares = 4 * NSPARE,
            cost_fail = COST_FAIL, cost_unclosed = COST_UNCLOSED, objective_hash = OBJ_HASH,
            crn_variance_reduction = isempty(vr_factors) ? NaN : _mean(vr_factors),
            ref_best_action = ref_best,
            ref_agrees_with_mc = (ref_best == best))
    return out, meta, refs
end

function print_summary(out, meta, refs = NamedTuple[])
    println("\n" * "="^94)
    println("K-ROLLOUT MONTE-CARLO Q LABELS   build_seed=$(meta.build_seed)  K=$(meta.K)  " *
            "hazard mtbf break/cell=$(meta.mtbf_break)/$(meta.mtbf_cell)s")
    println("="^94)
    @printf("%-14s %4s %12s %10s %14s %10s %8s %8s\n",
            "candidate", "K", "Q̂(cost)", "SE", "Δ vs best", "SE(paired)", "P(done)", "hz evts")
    println("-"^94)
    for c in sort(out, by = x -> x.Q)
        tag = c.is_best ? " <-BEST" : (c.tied_with_best ? " (tie)" : "")
        @printf("%-14s %4d %12.2f %10.2f %14.2f %10.2f %8.2f %8.2f%s\n",
                "$(c.action):$(c.name)", c.K, c.Q, c.se, c.delta_vs_best, c.se_paired,
                c.p_complete, c.mean_hz_events, tag)
    end
    println("-"^94)
    @printf("CRN variance-reduction factor (SE_unpaired / SE_paired) = %.2f×\n",
            meta.crn_variance_reduction)
    println("  (1.0 이면 짝짓기가 도움이 안 된 것. >1 이면 그만큼 K 를 아낀 셈.)")
    ties = [c for c in out if c.tied_with_best]
    isempty(ties) || println("TIED with best (구별 불가, 승리로 세면 안 됨): " *
                             join(["$(c.action):$(c.name)" for c in ties], ", "))
    ncap = sum(c.n_capped for c in out; init = 0)
    ncap == 0 || println("!! 사건 상한(max_events)에 걸린 rollout $(ncap)개 — 그 rollout 은 미래가 " *
                         "잘려 라벨이 낙관 편향된다. MC_MAX_EVENTS 를 올리거나 MTBF 를 올릴 것.")

    # --- 1-shot 기준선(기존 라벨러)과의 직접 비교 ---------------------------------------
    if !isempty(refs)
        println("-"^94)
        println("1-SHOT certainty-equivalent 기준선 (위험 프로세스 OFF = 기존 gen_oracle_fullsim 라벨):")
        for r in sort(refs, by = x -> x.cost)
            @printf("   %-14s cost=%10.2f  complete=%-3s closed=%3d/%3d\n",
                    "$(r.action):$(arm_name(r.action))", r.cost,
                    r.complete ? "YES" : "no", r.closed, r.total)
        end
        if meta.ref_agrees_with_mc
            println("   -> 1-shot 과 MC 의 argmin 이 **일치**($(meta.ref_best_action)). 이 상태에서는 두 라벨이 같은 결정을 준다.")
            println("      (일치한다고 1-shot 이 옳은 건 아니다 — 아래 P(done) 을 보면 1-shot 은 완주 확률을 전혀 못 본다.)")
        else
            println("   -> 1-shot 과 MC 의 argmin 이 **불일치**: 1-shot=$(meta.ref_best_action), MC=$(meta.best_action).")
            println("      1-shot 라벨로 학습한 surrogate 는 이 상태에서 체계적으로 틀린 결정을 배운다.")
        end
    end
    println("="^94)
end

# ---- entry points --------------------------------------------------------------------------
# ---- batch mode: 여러 유닛을 **한 프로세스 안에서** 순차 실행 ------------------------------
# 왜 필요한가: `MC_ONLY` 는 유닛마다 Julia 프로세스를 새로 띄우므로 패키지 로드 + JIT 를 매번
# 다시 문다. 유닛이 수십 개면 그 고정비가 시뮬레이션 시간 자체를 압도한다(실측: 유닛당 벽시계
# ~9분인데 그중 상당 부분이 기동 비용). 배치 모드는 기동을 한 번만 치르고 그 뒤로는 순수
# 시뮬 시간만 든다. 대규모 라벨 생성의 전제 조건.
#
#   MC_BATCH="0:1,1:1,0:2,1:2"        # (action:rollout) 목록
#   MC_BATCH_SEEDS="1,2,3"            # 여러 build seed 를 한 프로세스에서 (선택)
#
# 각 유닛이 끝날 때마다 CSV 에 append 하므로 도중에 죽어도 거기까지는 남는다.
const BATCH       = get(ENV, "MC_BATCH", "")
const BATCH_SEEDS = get(ENV, "MC_BATCH_SEEDS", "")

function main_batch(spec::String)
    t_start = time()
    units = [(parse(Int, split(u, ":")[1]), parse(Int, split(u, ":")[2]))
             for u in split(spec, ",") if !isempty(strip(u))]
    seeds = isempty(BATCH_SEEDS) ? [SEED] :
            [parse(Int, strip(s)) for s in split(BATCH_SEEDS, ",") if !isempty(strip(s))]
    println("[MC-batch] $(length(seeds)) seed x $(length(units)) unit = $(length(seeds)*length(units)) full-sims")
    t_ready = time()
    println("[MC-batch] startup(패키지+JIT) = $(round(t_ready - t_start; digits=1)) s")

    n = 0; t_sims = 0.0
    for bs in seeds, (a, k) in units
        # build seed 는 결정 상태 s 를 정한다. 프로세스 안에서 바꾸려면 전역 SEED 가 아니라
        # 호출 시점에 넘겨야 하는데, 현재 run_one 은 const SEED 를 읽는다 → 배치는 한 seed 씩.
        bs == SEED || (@warn "[MC-batch] build seed $bs != ORACLE_SEED $SEED — 건너뜀 (seed 는 프로세스당 하나)"; continue)
        t0 = time()
        hz_seed = SEED0 + k
        r = run_one(mc_prod(a); hz_seed = hz_seed)
        dt = time() - t0; t_sims += dt; n += 1
        @printf("  [%2d] seed=%d a=%d:%-12s k=%-3d complete=%-3s closed=%3d/%3d cost=%9.2f  brk=%d cell=%d  (%.1f s)\n",
                n, bs, a, arm_name(a), k, r.complete ? "YES" : "no", r.closed, r.total,
                scalar_cost(r), r.hz_break, r.hz_cell, dt)
        append_unit!(a, k, hz_seed, r)
    end
    n == 0 && return
    @printf("[MC-batch] %d sims, 평균 %.1f s/sim, 시뮬 합계 %.1f min, 총 %.1f min (기동 %.1f s)\n",
            n, t_sims / n, t_sims / 60, (time() - t_start) / 60, t_ready - t_start)
end

function main_unit(spec::String)
    parts = split(spec, ":")
    a = parse(Int, parts[1]); k = parse(Int, parts[2])
    hz_seed = SEED0 + k
    println("[MC] unit action=$a rollout=$k hazard_seed=$hz_seed build_seed=$SEED")
    r = run_one(mc_prod(a); hz_seed = hz_seed)
    @printf("  -> complete=%s closed=%d/%d makespan=%.1f cost=%.2f  post-decision events: brk=%d cell=%d (pending=%d)\n",
            r.complete ? "YES" : "no", r.closed, r.total, r.makespan, scalar_cost(r),
            r.hz_break, r.hz_cell, r.hz_pending_break)
    append_unit!(a, k, hz_seed, r)
    println("[MC] appended to $UNITCSV")
end

function main_aggregate()
    rows = read_units()
    isempty(rows) && (println("[MC] no unit rows in $UNITCSV — run some units first."); return)
    out, meta, refs = aggregate(rows)
    isempty(out) && (println("[MC] only reference rows found — run MC rollouts (rollout>=1)."); return)
    print_summary(out, meta, refs)
    write_json(SUMJSON, meta, out)
    println("wrote $SUMJSON")
end

function main_sweep()
    println("[MC] K=$K rollouts x actions=$(ACTIONS)  build_seed=$SEED  hot_swap=$HOT_SWAP  rvo=$RVO")
    println("[MC] = $(K * length(ACTIONS)) full simulations. 병렬로 돌리려면 MC_ONLY=\"a:k\" 사용.")
    # 전체 스윕은 처음부터 다시 만드는 것이므로 이 seed 의 **모든 샤드**를 지운다.
    # 자기 샤드만 지우면 이전 병렬 실행의 잔여 행이 조용히 집계에 섞인다.
    mkpath(OUTDIR); for fp in unit_csv_files(); rm(fp); end
    raw = NamedTuple[]

    # rollout 0 = 1-shot 기준선(위험 OFF). 먼저 돌려두면 뒤의 MC 결과와 나란히 볼 수 있다.
    if WANT_REF
        for a in ACTIONS
            r = run_one(mc_prod(a); hz_seed = nothing)
            @printf("  a=%d:%-12s REF  complete=%-3s closed=%3d/%3d  mk=%7.1f  cost=%9.2f  (1-shot, 위험 OFF)\n",
                    a, arm_name(a), r.complete ? "YES" : "no", r.closed, r.total,
                    r.makespan, scalar_cost(r))
            append_unit!(a, 0, -1, r)
        end
    end

    for k in 1:K, a in ACTIONS
        hz_seed = SEED0 + k
        r = run_one(mc_prod(a); hz_seed = hz_seed)
        @printf("  a=%d:%-12s k=%d  complete=%-3s closed=%3d/%3d  mk=%7.1f  cost=%9.2f  brk=%d cell=%d\n",
                a, arm_name(a), k, r.complete ? "YES" : "no", r.closed, r.total,
                r.makespan, scalar_cost(r), r.hz_break, r.hz_cell)
        append_unit!(a, k, hz_seed, r)
        push!(raw, r)
    end
    check_order_equivalence(raw)      # 스칼라 비용이 기존 사전식 순위를 재현하는지 점검
    main_aggregate()
end

# 직접 실행했을 때만 시뮬을 돌린다. 다른 파일이 include 하면(테스트가 그렇게 한다)
# 함수 정의만 가져가고 아무것도 실행하지 않는다.
if abspath(PROGRAM_FILE) == @__FILE__
    if AGGONLY
        main_aggregate()
    elseif !isempty(BATCH)
        main_batch(BATCH)
    elseif !isempty(ONLY)
        main_unit(ONLY)
    else
        main_sweep()
    end
end
