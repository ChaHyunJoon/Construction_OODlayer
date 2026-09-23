# =============================================================================
# tools/monitor/check_grammar_roundtrip.jl — 게이트 N-G8 의 측정 스크립트 (Task C6)
#
#   julia +lts --project=. tools/monitor/check_grammar_roundtrip.jl
#   python3 tools/smdp/gate_ng8.py results/smdp/ng8_roundtrip.json
#
# -----------------------------------------------------------------------------
# 무엇을 재는가
# -----------------------------------------------------------------------------
# "노출한 L2-a 문법(`LinearConstraint`·`Disjunction`)이 **의미상 동치인 다른 표현**과 같은
#  MILP 해를 내는가." 못 내면 그 문법은 `L_dsl` 보다 좁고, "LLM 이 새 제약을 만든다" 는 주장이
#  "LLM 이 더 약한 제약을 만든다" 가 된다.
#
# 🔴 **계획서가 지시한 왕복은 거의 항진명제다 — 그대로 발행하지 않는다.**
#   계획서 Step 1 의 표는 `ForbidWindow(v,lo,hi) ≡ Disjunction(tF[v]≤lo, t0[v]≥hi)` 를
#   N-G8 의 본체로 삼는다. 그런데 `_bigm_half!`(compiler.jl:158-174)가 내는 행은
#   `compile_constraint!(::ForbidWindow)`(compiler.jl:38-46)가 내는 행과 **구조적으로 동일**하다:
#   같은 방향, 같은 Big-M 상수(`1e5`), 같은 이진변수 하나. 두 표현이 **같은 행**을 내도록
#   만들어 놓고 같은 답이 나오는지 보는 것은 왕복 시험이 아니라 동어반복이다.
#   ⇒ 그 짝은 `tautological = true` 로 표시해서 싣고, **게이트의 통과 근거로는 안 쓴다**
#     (gate_ng8.py 가 그 필드를 읽고 NOTE 로만 찍는다). 대신 비퇴화 단언을 짝지어 둔다:
#     `moved_base` — 그 제약이 애초에 기저해를 움직였는가. 없으면 "둘 다 아무것도 안 했다"가
#     초록으로 지나간다.
#
# 🔴 **행 구조가 다른 진짜 왕복 넷을 대신 짰다.** (`tautological = false`)
#   각 짝의 좌변("native")과 우변("grammar")은 **행 수도 행 모양도 다르고**, 같은 답이 나오는
#   근거가 "같은 행을 냈다" 가 아니라 **논증**이다:
#
#   1. `dominated_disjunction`   — B ⟹ A 이면 `A ∨ B ≡ A`.
#        native  = A 한 줄 (평범한 행 1개, 이진변수 없음)
#        grammar = `Disjunction(B, A)` (Big-M 행 2개 + 이진변수 1개)
#        갈라지는 조건: Big-M 이 부족하거나(완화가 완화가 아님), 이진변수 극성이 뒤집혔거나
#        (∨ 가 ∧ 으로 조임), 이진변수가 연속으로 새면 전부 다른 답이 나온다.
#   2. `eq_half_disjunction`     — 위와 같은 논증인데 **지배당하는 쪽이 `:eq`** 다.
#        `_bigm_half!` 의 `:eq` 를 한 행으로 되돌리면 그 등식이 b 와 무관하게 언제나 성립해야
#        해서 ∨ 가 ∧ 으로 조용히 바뀐다 — 이 짝이 정확히 그것만 잡는다.
#   3. `scaled_coefficient`      — `1·tF ≥ r` ≡ `2·tF ≥ 2r`. 행렬의 행 자체가 다르다.
#        `_lin_expr` 이 계수를 흘리면 갈라진다.
#   4. `eq_vs_two_inequalities`  — `tF = r` (행 1개) ≡ `{tF ≤ r, tF ≥ r}` (행 2개, spec 2개).
#        `compile_constraint!(::LinearConstraint)` 의 rel 분기와 `compile_proposal!` 의
#        다중 spec 루프를 함께 태운다. 행 수가 **다르다** — 그래서 게이트는 행 수 일치를
#        요구하지 않는다(0 이 아님만 요구한다).
#
# 🔴 **`:xa` 는 emit 불가다 — 그래서 직접 타입 생성으로 짠다** (컨트롤러 지시 · D-9).
#   Task C2 가 `VarRef` 의 emit 표면(schema · TOOL_SCHEMA · ADVERTISED_VAR_KINDS · 프롬프트 ·
#   파서)에서 `:xa` 를 뺐다. 프롬프트에 후보 간선 목록이 없어 모델이 유효한 `(u,v)` 를 고를 수
#   없기 때문이다. **타입·컴파일러 메서드·`referenced_ids` 는 그대로 남아 있다.**
#   ⇒ 아래 `xa_*` 짝은 `CB.LinearConstraint(...CB.VarRef(:xa, ...))` 를 **손으로 만든다.**
#   ⚠️ 나중에 이 파일을 읽는 사람에게: "LLM 이 `:xa` 를 못 낸다" 는 **회귀가 아니라 D-9 결정**이다.
#
# 🔴 **이 판에서 `Xa` 축은 자유도가 0이다 — 실측**(아래 `fixture.n_xa_free` 가 매 실행마다 재잰다).
#   `formulate_milp` 은 `has_edge(sched,u,v)` 인 자리에도 `Xa[u,v]` 변수를 만들지만 곧바로
#   `@constraint(model, Xa[u,v] == 1)` 로 못박는다(essential_tg_coponents.jl:1111).
#   `assignment_mode = :greedy` 로 만든 이 판에서는 `Xa` 의 비영 원소가 **전부** 그 부류라
#   자유 결정변수가 하나도 없다. 귀결:
#     · `ForbidAgent` 는 구조 엣지를 절대 안 건드리므로(compiler.jl:77) **0행**을 낸다.
#     · `Xa[u,v] = 0` 류 제약은 강제된 `== 1` 과 모순 → **INFEASIBLE**.
#     · `Xa[u,v] = 1` 류 제약은 **중복** → 기저해 그대로.
#   ⇒ 그래서 `xa_forbid_infeasible` 짝은 "두 표현이 같은 **판정**(INFEASIBLE)에 도달하는가" 만
#     잰다. 그건 결속 증거가 아니고, JSON 이 `axis_degenerate = true` 로 그렇게 신고한다.
#     계획을 실제로 바꾸는 `:xa` 왕복은 이 판에서 **측정 불가**다(보고서 참조).
#
# -----------------------------------------------------------------------------
# 씬과 probe step
# -----------------------------------------------------------------------------
# 씬 생성은 SCENE-INCANTATION.md 의 정본(`return_env_before_sim = true` 필수).
# 🔴 **probe step 을 인용하지 않는다 — 스캔해서 고른다.** 아래 `probe_scan` 이 스텝을 밟으며
#   매 체크포인트에서 (nv · Xa 비영 · Xa 자유 · closed · active · base 목적값)을 다시 재고,
#   게이트가 요구하는 술어를 만족하는 **가장 이른** 스텝을 고른다. 그 스캔 표가 JSON 에 그대로
#   실린다. (이 판에서는 `formulate_milp` 이 `sched` 만 읽으므로 MILP 가 스텝 불변이고,
#    스캔이 그 사실 자체의 증거다 — 가정이 아니라 측정.)
#
# 🔴 **측정값은 디렉토리를 건너지 않는다**(CLAUDE.md: 결정성의 단위는 컴파일 캐시).
#   그래서 이 스크립트의 **모든 rhs 는 그 실행의 base 해에서 유도한다** — 리터럴 makespan 을
#   안 쓴다. 그리고 비교 대상 두 해는 **한 프로세스·한 디렉토리** 안에서 잇달아 푼다.
#
# 결정성: `Set`/`Dict` 를 순회하지 않는다. 엣지·로봇 목록은 전부 `sort!` 한다.
# 조용한 폴백 금지: 픽스처 술어가 깨지면 `error()` 로 죽는다(기본값으로 내려앉지 않는다).
# =============================================================================
using ConstructionBots
import Random
import Graphs
import JSON3
import SHA
using JuMP
using SparseArrays
const CB = ConstructionBots

const OUT_PATH  = get(ENV, "NG8_OUT",
                      joinpath(pkgdir(CB), "results", "smdp", "ng8_roundtrip.json"))
const MAX_STEP  = parse(Int, get(ENV, "NG8_MAX_STEP", "120"))
const STEP_GRID = parse(Int, get(ENV, "NG8_STEP_GRID", "20"))
const RTOL      = 1.0e-6

# --- 씬 (SCENE-INCANTATION.md 정본) -------------------------------------------
const ENV_  = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "ng8",
                                 num_robots = 6, assignment_mode = :greedy,
                                 n_spare_per_pool = 2,
                                 open_animation_at_end = false, save_animation = false,
                                 write_results = false, return_env_before_sim = true,
                                 rng = Random.MersenneTwister(1))
const SCHED = ENV_.sched
const NV    = Graphs.nv(SCHED)

_build(extra) = begin
    m = CB.formulate_milp(CB.SparseAdjacencyMILP(), SCHED, ENV_.scene_tree;
                          optimizer = CB._respec_optimizer(), extra_constraints = extra)
    set_silent(m.model)
    m
end
_nc(m)     = num_constraints(m; count_variable_in_set_constraints = false)
_prop(cs)  = CB.RespecProposal(CB.ConstraintSpec[cs...])
_nid(v)    = CB.get_vtx_id(SCHED, v)
# 해 벡터의 지문. 부동소수 잡음이 해시를 흔들지 않도록 9자리로 자른 뒤 SHA-256.
_t0hash(v) = bytes2hex(SHA.sha256(join((string(round(x; digits = 9)) for x in v), ",")))

"Xa 의 비영 자리를 (강제 엣지, 자유 결정변수)로 가른다. 정렬해서 돌려준다 — 결정적."
function _split_xa(Xa)
    rv = rowvals(Xa)
    forced = Tuple{Int,Int}[]
    free   = Tuple{Int,Int}[]
    for col in 1:size(Xa, 2), k in nzrange(Xa, col)
        u = rv[k]
        push!(Graphs.has_edge(SCHED, u, col) ? forced : free, (u, col))
    end
    return sort!(forced), sort!(free)
end

# --- probe step 스캔 ----------------------------------------------------------
# 술어: 이 게이트가 쓰려면 (a) 스케줄이 납작하지 않고, (b) base MILP 가 풀리고,
#       (c) makespan 이 0 이 아니고, (d) 시간창이 실제로 걸릴 만큼 긴 노드가 하나는 있어야 한다.
struct Probe
    step::Int; nv::Int; nc::Int; xa_nnz::Int; xa_forced::Int; xa_free::Int
    closed::Int; active::Int; objective::Float64; makespan::Float64
    v_max::Int; v_span::Int; span::Float64; feasible::Bool
end
_ok(p::Probe) = p.feasible && p.nv > 100 && p.nc > 1000 && p.makespan > 1.0 && p.span > 1.0e-9

function _probe(step::Int)
    milp = _build(nothing)
    optimize!(milp.model)
    feas = primal_status(milp.model) == CB.MOI.FEASIBLE_POINT
    t0 = feas ? value.(milp.model[:t0]) : zeros(NV)
    tF = feas ? value.(milp.model[:tF]) : zeros(NV)
    forced, free = _split_xa(milp.Xa)
    v_max  = argmax(tF)                       # 동점이면 최소 인덱스(argmax 규약) = 결정적
    v_span = argmax(tF .- t0)
    Probe(step, NV, _nc(milp.model), length(nonzeros(milp.Xa)), length(forced), length(free),
          length(ENV_.cache.closed_set), length(ENV_.cache.active_set),
          feas ? objective_value(milp.model) : NaN, tF[v_max],
          v_max, v_span, tF[v_span] - t0[v_span], feas)
end

"환경을 `n` 스텝 민다 (SCENE-INCANTATION 의 호출 순서: step → update_cache → set_sim_step)."
function _advance!(from::Int, n::Int)
    step = from
    for _ in 1:n
        CB.step_environment!(ENV_)
        CB.update_planning_cache!(ENV_, 0.0)
        step += 1
        CB.set_sim_step!(step)
    end
    return step
end

const SCAN = Probe[]
let step = 0
    while true
        push!(SCAN, _probe(step))
        (_ok(last(SCAN)) || step >= MAX_STEP) && break
        step = _advance!(step, STEP_GRID)
    end
end
const PROBE_STEP = last(SCAN).step
_ok(last(SCAN)) || error("N-G8: probe 스캔이 step $(MAX_STEP) 까지 비퇴화 픽스처를 못 찾았다 — " *
                         "게이트가 잴 것이 없다. 스캔: $(SCAN)")

# --- 기저해 ------------------------------------------------------------------
const BASE     = _build(nothing)
optimize!(BASE.model)
primal_status(BASE.model) == CB.MOI.FEASIBLE_POINT || error("N-G8: base MILP 가 안 풀린다")
const BASE_NC  = _nc(BASE.model)
const BASE_T0  = value.(BASE.model[:t0])
const BASE_TF  = value.(BASE.model[:tF])
const BASE_OBJ = objective_value(BASE.model)
const XA_FORCED, XA_FREE = _split_xa(BASE.Xa)
# 🔴 probe step 시점의 캐시 크기를 **여기서** 잡는다. 파일 끝의 step-invariance probe 가
#    `ENV_` 를 더 밀기 때문에, 나중에 읽으면 probe step 의 값이 아니다.
const N_CLOSED = length(ENV_.cache.closed_set)
const N_ACTIVE = length(ENV_.cache.active_set)

const V_MAX    = argmax(BASE_TF)
const NID_MAX  = _nid(V_MAX)
const MAKESPAN = BASE_TF[V_MAX]
const V_SPAN   = argmax(BASE_TF .- BASE_T0)
const NID_SPAN = _nid(V_SPAN)
const SPAN     = BASE_TF[V_SPAN] - BASE_T0[V_SPAN]

# 🔴 rhs 는 전부 여기서 **유도**된다. 리터럴 makespan 을 안 쓴다.
const D_BIND   = max(10.0, 0.25 * MAKESPAN)      # 결속시키는 여유 (base 를 확실히 움직인다)
const D_WORSE  = 10.0 * D_BIND                   # 지배당하는(훨씬 나쁜) 쪽
const W_LO     = BASE_T0[V_SPAN] + 0.25 * SPAN   # ForbidWindow 의 창 — base 를 관통한다
const W_HI     = BASE_T0[V_SPAN] + 0.75 * SPAN

# --- 측정 --------------------------------------------------------------------
"컴파일러가 **스스로 보고한** 행 수와 모델에 **실제로 들어간** 행 수를 함께 잰다.
 (반환값만 믿으면 0행을 내고도 '2개 넣었다' 고 말하는 구현이 초록으로 지나간다.)"
function _rows(specs)
    m = Model()
    @variable(m, t0[1:NV] >= 0.0)
    @variable(m, tF[1:NV] >= 0.0)
    # BASE.Xa 의 변수는 BASE.model 소속이라 다른 모델에 못 넣는다. 희소 패턴만 그대로 복제한다.
    nz = [@variable(m, binary = true) for _ in 1:length(nonzeros(BASE.Xa))]
    Xd = SparseMatrixCSC{VariableRef,Int}(size(BASE.Xa)..., copy(BASE.Xa.colptr),
                                          copy(rowvals(BASE.Xa)), nz)
    before   = _nc(m)
    reported = sum(CB.compile_constraint!(m, t0, tF, Xd, SCHED, cs) for cs in specs)
    return (reported = reported, actual = _nc(m) - before)
end

"제약 목록 하나를 세우고 풀어서 게이트가 읽는 레코드를 만든다."
function _measure(specs)
    milp  = _build(_prop(specs))
    added = _nc(milp.model) - BASE_NC
    optimize!(milp.model)
    feas  = primal_status(milp.model) == CB.MOI.FEASIBLE_POINT
    r     = _rows(specs)
    t0    = feas ? value.(milp.model[:t0]) : Float64[]
    return Dict(
        "n_constraints" => added,
        "rows_reported" => r.reported,
        "rows_actual"   => r.actual,
        "feasible"      => feas,
        "status"        => string(termination_status(milp.model)),
        # 🔴 INFEASIBLE 은 "목적값이 없다" 이지 "0" 이 아니다. 0 을 채우면 두 infeasible 이
        #    목적값 일치로 조용히 통과한다. `null` 로 낸다.
        "objective"     => feas ? objective_value(milp.model) : nothing,
        "t0_hash"       => feas ? _t0hash(t0) : nothing,
        # 비퇴화: 이 제약이 애초에 기저해를 움직였는가. INFEASIBLE 도 "움직였다" 다
        # (base 는 풀렸으니까) — 그 경우는 status 로 구분된다.
        "moved_base"    => !feas || !isapprox(t0, BASE_T0; rtol = 1.0e-9),
    )
end

const PAIRS    = Dict{String,Any}()
const CONTROLS = Dict{String,Any}()

function _pair!(name; claim, tautological, note = "", native, grammar, axis_degenerate = false)
    PAIRS[name] = Dict("claim" => claim, "tautological" => tautological, "note" => note,
                       "axis_degenerate" => axis_degenerate,
                       "native" => _measure(native), "grammar" => _measure(grammar))
    n, g = PAIRS[name]["native"], PAIRS[name]["grammar"]
    @info "N-G8 pair $(name)" tautological native_n=n["n_constraints"] grammar_n=g["n_constraints"] native_obj=n["objective"] grammar_obj=g["objective"] native_status=n["status"] grammar_status=g["status"]
    return PAIRS[name]
end

_lc(kind, id, rel, rhs; c = 1.0) = CB.LinearConstraint([(c, CB.VarRef(kind, id, nothing))], rel, rhs)

# --- 짝 0 — 계획서가 지시한 왕복. **항진적이다.** ------------------------------
# `Disjunction` 의 Big-M 반쪽이 `ForbidWindow` 의 행과 같은 방향·같은 상수(1e5)라
# 두 표현은 사실상 같은 행을 낸다. 독립적인 증거로 쓰지 않는다.
_pair!("forbid_window_vs_disjunction";
       claim = "ForbidWindow(v,lo,hi) ≡ Disjunction(tF[v] ≤ lo, t0[v] ≥ hi)",
       tautological = true,
       note = "near-tautological: _bigm_half!(compiler.jl:158-174) emits rows structurally " *
              "identical to compile_constraint!(::ForbidWindow)(compiler.jl:38-46) — same " *
              "orientation, same 1e5 constant. Kept for the record, paired with moved_base, " *
              "and NOT counted as independent evidence by gate_ng8.py.",
       native  = [CB.ForbidWindow(NID_SPAN, W_LO, W_HI)],
       grammar = [CB.Disjunction(_lc(:tF, NID_SPAN, :le, W_LO), _lc(:t0, NID_SPAN, :ge, W_HI))])

# --- 짝 1 — B ⟹ A 이면 A ∨ B ≡ A. 행 1개 vs Big-M 행 2개 + 이진변수 -------------
const A_BIND  = _lc(:tF, NID_MAX, :ge, MAKESPAN + D_BIND)
const B_WORSE = _lc(:tF, NID_MAX, :ge, MAKESPAN + D_WORSE)      # B ⟹ A (더 강한 하한)
const B_WEQ   = _lc(:tF, NID_MAX, :eq, MAKESPAN + D_WORSE)      # B_eq ⟹ A 이기도 하다

_pair!("dominated_disjunction";
       claim = "B ⟹ A  ⇒  (A ∨ B) ≡ A. native = A alone (1 plain row); " *
               "grammar = Disjunction(B, A) (2 Big-M rows + 1 binary)",
       tautological = false,
       note = "row structure differs (1 vs 2 + binary); the equality is an argument, not a " *
              "row identity. Diverges if the Big-M is too small, if the binary polarity is " *
              "flipped (∨ silently becomes ∧), or if the binary is relaxed to continuous.",
       native  = [A_BIND],
       grammar = [CB.Disjunction(B_WORSE, A_BIND)])

_pair!("eq_half_disjunction";
       claim = "same argument with the dominated half an :eq — (A ∨ (tF = r_worse)) ≡ A",
       tautological = false,
       note = "this is the pair that catches _bigm_half!'s :eq being collapsed back to one " *
              "unconditional row, which turns ∨ into ∧.",
       native  = [A_BIND],
       grammar = [CB.Disjunction(B_WEQ, A_BIND)])

# --- 짝 2 — 계수 스케일링. 행렬의 행 자체가 다르다 ------------------------------
_pair!("scaled_coefficient";
       claim = "1·tF[v] ≥ r  ≡  2·tF[v] ≥ 2r",
       tautological = false,
       note = "different matrix row (coefficient 2 vs 1). Diverges if _lin_expr drops or " *
              "misapplies the coefficient.",
       native  = [A_BIND],
       grammar = [_lc(:tF, NID_MAX, :ge, 2.0 * (MAKESPAN + D_BIND); c = 2.0)])

# --- 짝 3 — 등식 1행 vs 부등식 2행 ---------------------------------------------
_pair!("eq_vs_two_inequalities";
       claim = "tF[v] = r  ≡  {tF[v] ≤ r, tF[v] ≥ r}",
       tautological = false,
       note = "row COUNTS differ (1 vs 2) on purpose — the gate must not require equal row " *
              "counts, only non-zero ones. Exercises compile_proposal!'s multi-spec loop.",
       native  = [_lc(:tF, NID_MAX, :eq, MAKESPAN + D_BIND)],
       grammar = [_lc(:tF, NID_MAX, :le, MAKESPAN + D_BIND),
                  _lc(:tF, NID_MAX, :ge, MAKESPAN + D_BIND)])

# --- 짝 4 — `:xa` (직접 타입 생성. LLM 이 emit 할 수 없다 — D-9) -----------------
# 🔴 이 판의 `Xa` 는 자유도가 0이다(위 헤더). 그래서 이 짝이 재는 것은 **판정의 일치**뿐이다.
#   `ForbidAgent` 가 내는 행 모양(`Xa[u,v] == 0`)을 K 줄로 쓴 것 vs 그것을 한 줄로 합친 것.
const XA_K     = min(5, length(XA_FORCED))
const XA_EDGES = XA_FORCED[1:XA_K]           # 이미 정렬돼 있다 — 결정적
XA_K >= 1 || error("N-G8: Xa 에 비영 자리가 없다 — :xa 짝을 만들 수 없다")

_pair!("xa_forbid_infeasible";
       claim = "K rows of `Xa[u,v] = 0` (what compile_constraint!(::ForbidAgent) emits) " *
               "≡ one row `Σ Xa[u,v] ≤ 0` (valid because Xa is binary, hence ≥ 0)",
       tautological = false,
       axis_degenerate = length(XA_FREE) == 0,
       note = "🔴 built by DIRECT TYPE CONSTRUCTION: `:xa` was removed from the emittable " *
              "surface by C2 (schema · TOOL_SCHEMA · ADVERTISED_VAR_KINDS · prompt · parser) " *
              "because the prompt ships no candidate-edge list, so the model cannot " *
              "instantiate a valid (u,v). The type, the compiler method and referenced_ids " *
              "all REMAIN. That the LLM cannot emit :xa is decision D-9, NOT a regression. " *
              "🔴 On this board Xa has ZERO free decision variables (every nonzero is a " *
              "structural edge pinned to 1 at essential_tg_coponents.jl:1111), so both " *
              "encodings land on INFEASIBLE. That is agreement on a DISCRIMINATING verdict " *
              "(base is feasible), but it is NOT evidence that the two forms steer the plan " *
              "the same way — nothing can steer this axis here.",
       native  = [CB.LinearConstraint([(1.0, CB.VarRef(:xa, _nid(u), _nid(v)))], :eq, 0.0)
                  for (u, v) in XA_EDGES],
       grammar = [CB.LinearConstraint([(1.0, CB.VarRef(:xa, _nid(u), _nid(v)))
                                       for (u, v) in XA_EDGES], :le, 0.0)])

# =============================================================================
# 🔴 음성 대조 — **초록불은 증거가 아니다.** 게이트가 이 넷을 전부 읽고 기대와 다르면 FAIL 한다.
# =============================================================================
function _control!(name; claim, expect, holds::Bool, measured)
    CONTROLS[name] = Dict("claim" => claim, "expect" => expect,
                          "holds" => holds, "measured" => measured)
    @info "N-G8 control $(name)" holds measured
    return CONTROLS[name]
end

# NC1 — 행이 늘어도 해는 안 움직인다. "n_constraints > 0" 이 증거가 아니라는 증거.
let m = _measure([_lc(:tF, NID_MAX, :ge, 0.0)])
    _control!("noop_row_does_not_move_solution";
              claim  = "a row that is already satisfied adds 1 row and changes nothing",
              expect = "n_constraints == 1 AND moved_base == false",
              holds  = m["n_constraints"] == 1 && m["moved_base"] == false,
              measured = m)
end

# NC2 — 행이 솔버에 진짜로 들어간다는 결정적 증거(모델이 죽는다).
let m = _measure([_lc(:tF, NID_MAX, :le, -1.0)])
    _control!("infeasible_row_reaches_solver";
              claim  = "tF ≤ -1 must make the MILP INFEASIBLE",
              expect = "feasible == false",
              holds  = m["feasible"] == false,
              measured = m)
end

# NC3 — 🔴 **비교 자체가 빨강을 낼 수 있는가.** 코드를 안 고치고 재는 발산 증인.
#   A_weak 는 base 가 이미 만족하므로 `A_weak ∨ A ≡ A_weak` 이고, 그 답은 base 다.
#   그래서 이 짝은 **반드시 갈라져야** 한다. 안 갈라지면 비교 함수가 고장 난 것이다.
let a = _measure([A_BIND]),
    w = _measure([CB.Disjunction(_lc(:tF, NID_MAX, :ge, 0.0), A_BIND)])
    diverged = a["objective"] !== nothing && w["objective"] !== nothing &&
               abs(a["objective"] - w["objective"]) / max(abs(a["objective"]), 1e-12) > RTOL
    _control!("comparison_can_go_red";
              claim  = "A vs Disjunction(A_weak, A) — A_weak is satisfied by base, so the " *
                       "disjunction collapses to base and MUST differ from A",
              expect = "objectives differ by more than RTOL",
              holds  = diverged,
              measured = Dict("A" => a, "disjunction_with_weak_half" => w,
                              "base_objective" => BASE_OBJ))
end

# NC4 — 지배 논증이 공허하지 않은가. B 혼자가 A 혼자보다 **정말로 나빠야** 짝 1·2 가 의미를 갖는다.
#   (B 가 A 와 같은 답을 낸다면 "이접이 더 나은 쪽을 골랐다" 를 증명한 게 아니다.)
let a = _measure([A_BIND]), b = _measure([B_WORSE]), be = _measure([B_WEQ])
    ok = a["objective"] !== nothing && b["objective"] !== nothing && be["objective"] !== nothing &&
         b["objective"] > a["objective"] + 1.0 && be["objective"] > a["objective"] + 1.0 &&
         a["objective"] > BASE_OBJ + 1.0
    _control!("dominated_half_is_really_worse";
              claim  = "the dominated half B, solved ALONE, must be strictly worse than A " *
                       "alone, and A alone must be strictly worse than base — otherwise the " *
                       "dominated-disjunction pairs prove nothing",
              expect = "obj(B) > obj(A) + 1 AND obj(B_eq) > obj(A) + 1 AND obj(A) > base + 1",
              holds  = ok,
              measured = Dict("A" => a["objective"], "B" => b["objective"],
                              "B_eq" => be["objective"], "base" => BASE_OBJ))
end

# NC5 — `:xa` 축이 실제로 퇴화했는가(그리고 반대 방향은 중복인가). 짝 4 의 해석을 못박는다.
let redundant = _measure([CB.LinearConstraint([(1.0, CB.VarRef(:xa, _nid(u), _nid(v)))
                                               for (u, v) in XA_EDGES], :ge, Float64(XA_K))])
    _control!("xa_axis_is_degenerate";
              claim  = "every Xa nonzero on this board is a structural edge pinned to 1, so " *
                       "`Σ Xa ≥ K` is redundant (base solution survives) while `Σ Xa ≤ 0` is " *
                       "infeasible. Both directions measured.",
              expect = "n_xa_free == 0 AND the `≥ K` form is feasible AND does not move base",
              holds  = length(XA_FREE) == 0 && redundant["feasible"] == true &&
                       redundant["moved_base"] == false,
              measured = Dict("n_xa_free" => length(XA_FREE), "n_xa_forced" => length(XA_FORCED),
                              "require_all_form" => redundant))
end

# NC6 — 컴파일러의 자기 보고가 거짓말을 안 하는가(모든 짝에 대해).
let bad = String[]
    for (name, p) in sort!(collect(PAIRS); by = first), side in ("native", "grammar")
        p[side]["rows_reported"] == p[side]["rows_actual"] || push!(bad, "$(name).$(side)")
    end
    _control!("compiler_row_count_is_honest";
              claim  = "compile_constraint!'s return value equals the rows it actually added",
              expect = "no mismatching side",
              holds  = isempty(bad),
              measured = Dict("mismatching_sides" => bad))
end

# =============================================================================
# 사후 probe — 여기부터는 `ENV_` 를 **민다**(짝 측정이 전부 끝난 뒤여야 한다).
# =============================================================================

# 🔴 "왜 step $(PROBE_STEP) 에서 재도 되는가" 를 인용이 아니라 **측정**으로 답한다.
#   `formulate_milp` 은 `sched` 만 읽고 `cache` 는 안 읽는다. 그렇다면 스텝을 더 밀어도 MILP 가
#   그대로여야 한다 — 아래가 그 예측을 두 체크포인트에서 검증한다. 어긋나면 probe step 선택이
#   실제로 결과를 가르는 것이고, 그건 게이트가 알아야 할 사실이다.
const INVARIANCE = Probe[last(SCAN)]
let step = PROBE_STEP
    for _ in 1:2
        step = _advance!(step, STEP_GRID)
        push!(INVARIANCE, _probe(step))
    end
end
const STEP_INVARIANT = all(p -> p.nv == INVARIANCE[1].nv && p.nc == INVARIANCE[1].nc &&
                                p.xa_nnz == INVARIANCE[1].xa_nnz &&
                                p.xa_free == INVARIANCE[1].xa_free &&
                                isapprox(p.objective, INVARIANCE[1].objective; rtol = RTOL),
                           INVARIANCE)
_control!("milp_is_step_invariant";
          claim  = "formulate_milp reads `sched`, not `cache` — so stepping the env must not " *
                   "change the MILP. This is why probing at step $(PROBE_STEP) is not a lucky " *
                   "quote. Measured at $(length(INVARIANCE)) checkpoints.",
          expect = "same nv / n_constraints / Xa pattern / base objective at every checkpoint",
          holds  = STEP_INVARIANT,
          measured = Dict("checkpoints" => [Dict("step" => p.step, "n_constraints" => p.nc,
                                                 "xa_nnz" => p.xa_nnz, "xa_free" => p.xa_free,
                                                 "objective" => p.objective) for p in INVARIANCE]))

# 🔴 선택적 probe — "진짜 `ForbidAgent ≡ Σ Xa = 0` 왕복을 왜 못 짰는가" 의 증거.
#   `NG8_FORBIDAGENT_PROBE=1` 로 켠다(기본 꺼짐: 120초 이상 걸리고 `ENV_` 를 파괴적으로 고친다).
#   `release_pending_assignments!` 는 구조 엣지를 풀어 후보 엣지를 만들어 준다 — 그래야
#   `ForbidAgent` 가 0행이 아니게 된다. 그런데 그렇게 만든 MIP 는 **수렴하지 않는다.**
#   수렴 안 하는 두 해를 목적값으로 비교하는 것은 게이트가 아니라 잡음이므로, 이 축의 왕복은
#   이 판에서 **측정 불가**로 신고한다.
const FA_PROBE = if get(ENV, "NG8_FORBIDAGENT_PROBE", "0") == "1"
    rids = sort!([CB.entity(CB.get_node_from_id(SCHED, _nid(v))).id
                  for v in Graphs.vertices(SCHED)
                  if CB.get_node_from_id(SCHED, _nid(v)) isa CB.RobotStart]; by = string)
    isempty(rids) && error("N-G8: RobotStart 노드가 없다")
    rid = first(rids)
    inv = CB.build_invariant(ENV_)
    closed_ids = Set{CB.AbstractID}(_nid(v) for v in ENV_.cache.closed_set)
    active_ids = Set{CB.AbstractID}(_nid(v) for v in ENV_.cache.active_set)
    CB.RESPEC_FROZEN[] = closed_ids
    CB.RESPEC_PINNED[] = union(closed_ids, active_ids)
    rows_before = _nc(_build(_prop([CB.ForbidAgent(rid, 0.0)])).model) - BASE_NC
    removed = CB.release_pending_assignments!(ENV_, inv; faulted = rid)
    post = _build(nothing)
    set_time_limit_sec(post.model, 120.0)
    optimize!(post.model)
    fa = _build(_prop([CB.ForbidAgent(rid, 0.0)]))
    Dict("agent" => string(rid),
         "rows_before_surgery" => rows_before,          # 실측 0 — 구조 엣지는 절대 안 건드린다
         "released_edges" => length(removed),
         "post_xa_nnz" => length(nonzeros(post.Xa)),
         "post_xa_free" => length(_split_xa(post.Xa)[2]),
         "post_n_constraints" => _nc(post.model),
         "post_termination" => string(termination_status(post.model)),
         "post_relative_gap" => relative_gap(post.model),
         "forbid_agent_rows" => _nc(fa.model) - _nc(post.model),
         "verdict" => "post-surgery MIP does not converge -> the ForbidAgent round-trip is " *
                      "NOT measurable on this board")
else
    nothing
end
FA_PROBE === nothing || @info "N-G8 ForbidAgent probe" FA_PROBE

# --- 출력 --------------------------------------------------------------------
const FIXTURE = Dict(
    "probe_step"        => PROBE_STEP,
    "nv"                => NV,
    "base_n_constraints" => BASE_NC,
    "base_objective"    => BASE_OBJ,
    "base_makespan"     => MAKESPAN,
    "base_feasible"     => true,
    "n_xa_nonzeros"     => length(nonzeros(BASE.Xa)),
    "n_xa_forced"       => length(XA_FORCED),
    "n_xa_free"         => length(XA_FREE),
    "n_closed"          => N_CLOSED,
    "n_active"          => N_ACTIVE,
    "v_max"             => V_MAX,  "v_span" => V_SPAN, "span" => SPAN,
    "window"            => [W_LO, W_HI],
    "d_bind"            => D_BIND, "d_worse" => D_WORSE,
    "probe_scan"        => [Dict("step" => p.step, "nv" => p.nv, "n_constraints" => p.nc,
                                 "xa_nnz" => p.xa_nnz, "xa_forced" => p.xa_forced,
                                 "xa_free" => p.xa_free, "closed" => p.closed,
                                 "active" => p.active, "objective" => p.objective,
                                 "makespan" => p.makespan, "span" => p.span,
                                 "feasible" => p.feasible, "accepted" => _ok(p))
                            for p in SCAN],
    "forbid_agent_probe" => FA_PROBE,
)

const META = Dict(
    "task"        => "C6 / gate N-G8",
    "scene"       => "colored_8x8.ldr · num_robots=6 · :greedy · n_spare_per_pool=2 · " *
                     "MersenneTwister(1) · return_env_before_sim=true",
    "one_directory_one_session" => true,
    "note"        => "🔴 every rhs is DERIVED from this run's base solution — no literal " *
                     "makespan is quoted, because a measured number does not transfer " *
                     "between directories (recompiling re-rolls the assignment DAG).",
    "xa_emittable" => false,
    "xa_note"     => "`:xa` is off the LLM emit surface by decision D-9 (C2). The type, the " *
                     "compiler method and referenced_ids remain; the xa_* pair is built by " *
                     "direct type construction. Not a regression.",
    "rtol"        => RTOL,
    "julia"       => string(VERSION),
)

mkpath(dirname(OUT_PATH))
open(OUT_PATH, "w") do io
    JSON3.write(io, Dict("meta" => META, "fixture" => FIXTURE,
                         "pairs" => PAIRS, "negative_controls" => CONTROLS))
end
@info "N-G8 wrote $(OUT_PATH)" pairs=length(PAIRS) controls=length(CONTROLS) probe_step=PROBE_STEP base_objective=BASE_OBJ n_xa_free=length(XA_FREE)
