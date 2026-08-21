# =============================================================================
# test/respec_grammar.jl — Task C2 게이트: MILP 제약 문법 (L2-a)
#   julia +lts --project=. test/respec_grammar.jl
#   🔴 runtests.jl 에 싣지 않는다 (Global Constraint: SMDP 계열은 독립 프로세스).
#
# 이 시험이 막으려는 실패 모양은 **hollow admit** 이다: 문법이 컴파일은 되는데
# 모델에 아무 행도 안 넣거나(0개 제약), 행은 넣는데 **해를 하나도 안 바꾸는** 것.
# 그래서 세 가지를 따로 잰다:
#   (1) 행 수      — compile 이 실제로 num_constraints 를 늘리는가 (그리고 반환값이 거짓말을 안 하는가)
#   (2) 결속       — 그 행이 최적해를 실제로 바꾸는가 (음성 대조와 짝지어서)
#   (3) 등가       — Disjunction(tF≤lo, t0≥hi) 가 ForbidWindow 와 같은 해를 내는가
#
# 🔴 **음성 대조를 먼저 실측한다** (Global Constraint). 이 파일은 두 개의 음성 대조를 갖는다:
#   · NON-BINDING: 같은 문법·같은 변수인데 rhs 를 느슨한 쪽으로 준 제약 → 행은 +1 인데 해는 그대로.
#     (계획서 브리프의 `tF ≤ 42.0` 이 이 픽스처에서 정확히 이 경우다 — 실측 makespan 31.9~34.65 < 42.)
#     "행이 늘었다" 를 "제약이 걸렸다" 로 읽으면 안 된다는 것을 이 대조가 증명한다.
#   · INFEASIBLE:  tF ≤ -1 → MILP 가 실제로 INFEASIBLE 이 된다. 행이 모델 안에 진짜로 들어 있다는 증거.
#
# 🔴 픽스처 비퇴화 실측(2026-08-21, 이 파일이 실행 시점에 다시 단언한다):
#   nv(sched) = 342 · n_candidate_edges(nnz Xa) = 423 · base num_constraints = 61552
#   ⚠️ 후보 배정 엣지 423개 중 **최적해에서 선택된 것은 0개**다(greedy 로 이미 구조 엣지가 박혀 있다).
#      그래서 이 판에서는 `Xa[u,v] == 0` 류 제약이 해를 못 바꾼다 — 결속(2)의 증거는 t0/tF 축에서 낸다.
#      `:xa` 는 "실제 결정변수로 해석되는가 + 행이 1개 늘어나는가" 까지만 잰다(과장하지 않는다).
#
# 🔴 **base makespan 을 리터럴로 적지 않는다 — 재컴파일마다 갈린다.** 같은 디렉토리·같은 시드
#   (`MersenneTwister(1)`)로 세 번 재서 **34.65 · 32.925 · 31.900** 이 나왔다(사이에 `src/` 를
#   고쳐 재컴파일이 일어났다). CLAUDE.md 가 이미 적어 둔 "결정성의 단위는 프로세스가 아니라
#   디렉토리(= 컴파일 캐시)" 잡음이고, 이 태스크의 변경과 무관하다.
#   ⇒ 그래서 이 파일은 **모든 rhs 를 실행 시점의 base 해에서 유도한다**(MAKESPAN ± Δ).
#     리터럴 42.0 을 결속 판정에 쓰면 그 판정이 잡음에 매달린다 — 실제로 34.65/32.925/31.900
#     세 경우 모두 `tF ≤ 42` 는 **결속되지 않는다**(그래서 그걸 음성 대조로 쓴다).
#
# 씬 생성은 SCENE-INCANTATION.md 의 정본을 따른다 (`return_env_before_sim = true` 필수 —
# 없으면 판을 88초 끝까지 굴리고 `Tuple` 을 돌려준다).
#
# ⚠️ 브리프는 헬퍼를 `test/smdp_fixtures.jl` 에 두라고 하지만 그 파일은 이 브랜치에 **없다**
#    (계획서 line 2108 기준 다른 태스크가 만든다). 레인 간 충돌을 만들지 않으려고
#    헬퍼를 이 파일 안에 자족적으로 둔다.
# =============================================================================
using ConstructionBots, Test
import Random
import Graphs
using JuMP
using SparseArrays
const CB = ConstructionBots

const ENV_ = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "respec_grammar",
                                num_robots = 6, assignment_mode = :greedy,
                                n_spare_per_pool = 2,
                                open_animation_at_end = false, save_animation = false,
                                write_results = false, return_env_before_sim = true,
                                rng = Random.MersenneTwister(1))
const SCHED = ENV_.sched

# --- 헬퍼 -------------------------------------------------------------------
_build(extra) = CB.formulate_milp(CB.SparseAdjacencyMILP(), SCHED, ENV_.scene_tree;
                                  optimizer = CB._respec_optimizer(), extra_constraints = extra)
_nconstr(m) = num_constraints(m; count_variable_in_set_constraints = false)
_prop(cs) = CB.RespecProposal(CB.ConstraintSpec[cs])

const BASE      = _build(nothing)
const BASE_NC   = _nconstr(BASE.model)
const N_CAND_E  = length(nonzeros(BASE.Xa))

"컴파일이 모델에 실제로 추가한 행 수 (이진 보조변수의 정수성 제약은 세지 않는다)."
_count_added_constraints(cs) = _nconstr(_build(_prop(cs)).model) - BASE_NC

"제약을 넣고 푼 뒤의 t0 벡터. 풀리지 않으면 `nothing`."
function _solved_times(cs)
    milp = _build(cs === nothing ? nothing : _prop(cs))
    optimize!(milp.model)
    primal_status(milp.model) == CB.MOI.FEASIBLE_POINT || return nothing
    return value.(milp.model[:t0])
end

function _solved(cs)
    milp = _build(cs === nothing ? nothing : _prop(cs))
    optimize!(milp.model)
    return milp
end

const BASE_M = _solved(nothing)
const BASE_T0 = value.(BASE_M.model[:t0])
const BASE_TF = value.(BASE_M.model[:tF])
const BASE_OBJ = objective_value(BASE_M.model)

# 결정적 선택 — 정렬/최소 인덱스로만 고른다 (Set/Dict 순회 없음).
const V_MAX     = argmax(BASE_TF)                  # 동점이면 최소 인덱스 (argmax 규약)
const NID_MAX   = CB.get_vtx_id(SCHED, V_MAX)
const MAKESPAN  = BASE_TF[V_MAX]
const V_MID     = findfirst(v -> 8.0 < BASE_T0[v] < 18.0 && BASE_TF[v] > BASE_T0[v] + 1e-9,
                            1:Graphs.nv(SCHED))
# 🔴 `_nid_mid()` 를 여기서 계산하지 않는다. 픽스처가 납작해져 `V_MID === nothing` 이면
#    `get_vtx_id(SCHED, nothing)` 이 **testset 밖에서** 터져 "비퇴화를 먼저 단언한다"는 성질이
#    깔끔한 빨강이 아니라 요란한 크래시가 된다. 필요한 자리에서 지연 계산한다.
_nid_mid() = (V_MID === nothing && error("픽스처 퇴화: 창 [10,20] 과 겹치는 노드가 없다");
              CB.get_vtx_id(SCHED, V_MID))

@testset "🔴 픽스처가 비퇴화다 (이걸 먼저 단언한다)" begin
    @test Graphs.nv(SCHED) > 100
    @test N_CAND_E > 0                       # 실측 423. 0 이면 :xa 가 결정변수로 해석될 수 없다
    @test BASE_NC > 1000                     # 실측 61552
    @test primal_status(BASE_M.model) == CB.MOI.FEASIBLE_POINT
    @test MAKESPAN > 1.0                     # 실측 34.65
    @test V_MID !== nothing                  # 창 [10,20] 과 겹치는 노드가 존재한다
    @test BASE_T0[V_MID] < 20.0 && BASE_TF[V_MID] > 10.0   # ForbidWindow(10,20) 이 실제로 걸린다
    @info "픽스처: nv=$(Graphs.nv(SCHED)) n_candidate_edges=$(N_CAND_E) base_nc=$(BASE_NC) " *
          "makespan=$(MAKESPAN) V_MAX=$(V_MAX) V_MID=$(V_MID) " *
          "mid[t0,tF]=($(BASE_T0[V_MID]),$(BASE_TF[V_MID]))"
end

@testset "문법이 타입 검사를 통과한다" begin
    lc = CB.LinearConstraint([(1.0, CB.VarRef(:tF, NID_MAX, nothing))], :le, 42.0)
    @test lc isa CB.ConstraintSpec
    @test CB.referenced_ids(lc) == (NID_MAX,)
    dj = CB.Disjunction(lc, CB.LinearConstraint([(1.0, CB.VarRef(:t0, NID_MAX, nothing))], :ge, 99.0))
    @test dj isa CB.ConstraintSpec
    @test NID_MAX in CB.referenced_ids(dj)
end

@testset "🔴 컴파일이 0 이 아닌 제약을 낸다 (hollow admit 방지)" begin
    lc = CB.LinearConstraint([(1.0, CB.VarRef(:tF, NID_MAX, nothing))], :le, 42.0)
    n  = _count_added_constraints(lc)
    @test n >= 1
    @test n == 1                                       # 정확히 한 행
    dj = CB.Disjunction(lc, CB.LinearConstraint([(1.0, CB.VarRef(:t0, NID_MAX, nothing))], :ge, 99.0))
    @test _count_added_constraints(dj) >= 2             # Big-M 이접은 제약 둘 + 이진변수 하나
    @test _count_added_constraints(dj) == 2

    # 🔴 컴파일러의 **반환값이 거짓말을 하지 않는가** — 실제 행 수와 같아야 한다.
    #    (반환값만 믿으면 0행을 내고도 "2개 넣었다" 고 보고하는 구현이 초록으로 지나간다.)
    for cs in (lc, dj)
        m = Model()
        @variable(m, t0[1:Graphs.nv(SCHED)] >= 0.0)
        @variable(m, tF[1:Graphs.nv(SCHED)] >= 0.0)
        before = _nconstr(m)
        r = CB.compile_constraint!(m, t0, tF, BASE.Xa, SCHED, cs)
        @test r == _nconstr(m) - before
    end

    # 항이 없는 제약은 hollow admit 이므로 생성 자체가 죽는다
    @test_throws Exception CB.LinearConstraint(Tuple{Float64,CB.VarRef}[], :le, 1.0)

    # :xa 도 실제 결정변수로 해석돼 한 행을 낸다 (이 판에서 결속되지는 않는다 — 헤더 참조)
    rv = rowvals(BASE.Xa)
    uv = nothing
    for col in 1:size(BASE.Xa, 2), k in nzrange(BASE.Xa, col)
        uv = (rv[k], col); break
    end
    @test uv !== nothing
    xa_cs = CB.LinearConstraint([(1.0, CB.VarRef(:xa, CB.get_vtx_id(SCHED, uv[1]),
                                                     CB.get_vtx_id(SCHED, uv[2])))], :le, 1.0)
    @test _count_added_constraints(xa_cs) == 1
    @test length(CB.referenced_ids(xa_cs)) == 2
end

@testset "🔴 제약이 MILP 의 해를 **실제로 바꾼다** (음성 대조와 짝지어)" begin
    # 음성 대조 A — NON-BINDING: 같은 변수, 느슨한 rhs. 행은 늘지만 해는 그대로.
    #   (브리프의 `tF ≤ 42.0` 이 이 픽스처에서 정확히 이 경우다: makespan 31.9~34.65 < 42)
    loose = CB.LinearConstraint([(1.0, CB.VarRef(:tF, NID_MAX, nothing))], :le, MAKESPAN + 10.0)
    @test _count_added_constraints(loose) == 1
    t_loose = _solved_times(loose)
    @test t_loose !== nothing
    @test isapprox(t_loose, BASE_T0; rtol = 1e-9)        # ← 해가 그대로다. 행 수는 증거가 아니다.

    # 양성: 같은 변수, 같은 문법, 결속되는 rhs 하나만 뒤집는다.
    tight = CB.LinearConstraint([(1.0, CB.VarRef(:tF, NID_MAX, nothing))], :ge, MAKESPAN + 10.0)
    mt = _solved(tight)
    @test primal_status(mt.model) == CB.MOI.FEASIBLE_POINT
    @test value(mt.model[:tF][V_MAX]) >= MAKESPAN + 10.0 - 1e-6   # 제약이 지켜진다
    @test objective_value(mt.model) > BASE_OBJ + 1.0              # 목적값이 실제로 갈린다
    @test !isapprox(value.(mt.model[:t0]), BASE_T0; rtol = 1e-9)  # 해가 실제로 갈린다

    # 음성 대조 B — INFEASIBLE: 행이 모델 안에 진짜로 들어 있다는 결정적 증거.
    dead = CB.LinearConstraint([(1.0, CB.VarRef(:tF, NID_MAX, nothing))], :le, -1.0)
    @test _solved_times(dead) === nothing                         # MILP 가 실제로 못 푼다

    # :eq 도 결속된다
    eqc = CB.LinearConstraint([(1.0, CB.VarRef(:tF, NID_MAX, nothing))], :eq, MAKESPAN + 5.0)
    me = _solved(eqc)
    @test primal_status(me.model) == CB.MOI.FEASIBLE_POINT
    @test isapprox(value(me.model[:tF][V_MAX]), MAKESPAN + 5.0; atol = 1e-6)
end

@testset "🔴 문법 왕복 — ForbidWindow 와 같은 해를 낸다 (게이트 N-G8)" begin
    fw = CB.ForbidWindow(_nid_mid(), 10.0, 20.0)
    dj = CB.Disjunction(
        CB.LinearConstraint([(1.0, CB.VarRef(:tF, _nid_mid(), nothing))], :le, 10.0),
        CB.LinearConstraint([(1.0, CB.VarRef(:t0, _nid_mid(), nothing))], :ge, 20.0))

    # 비퇴화 — 창이 실제로 걸려서 해가 base 와 갈린다. 이게 아니면 왕복 시험이 항진명제가 된다.
    t_fw = _solved_times(fw)
    @test t_fw !== nothing
    @test !isapprox(t_fw, BASE_T0; rtol = 1e-9)

    @test _count_added_constraints(fw) == _count_added_constraints(dj)
    @test _solved_times(fw) ≈ _solved_times(dj) rtol = 1e-6
end

@testset "🔴 문법 밖은 거부한다 (조용한 폴백 금지)" begin
    @test_throws Exception CB.VarRef(:bogus, NID_MAX, nothing)
    @test_throws Exception CB.LinearConstraint([(1.0, CB.VarRef(:t0, NID_MAX, nothing))], :lt, 1.0)
    # xa 는 노드 둘을 요구한다 — 하나만 주면 죽는다
    @test_throws Exception CB.VarRef(:xa, NID_MAX, nothing)
    # 반대로 t0/tF 는 노드 둘을 받지 않는다
    @test_throws Exception CB.VarRef(:t0, NID_MAX, _nid_mid())

end

# =============================================================================
# 🔴 해석 불가능한 참조는 **예외가 아니라 Reject** 다 (수정 라운드 2)
# -----------------------------------------------------------------------------
# 이전 판의 이 시험은 `@test_throws Exception _count_added_constraints(...)` 로 **크래시 경로를
# 정답으로 못박고 있었다.** 그건 이 태스크가 딛고 선 계약과 어긋난다 —
# "verify() 는 전이함수의 문이고 거부는 NOOP 과 같은 전이"(llm_bridge.jl:62).
# 예외는 전이가 아니라 전이의 부재다. 아래는 그 단언을 **뒤집는다**.
# =============================================================================
@testset "🔴 해석 불가능한 참조는 Reject 다 (예외로 시뮬을 무너뜨리지 않는다)" begin
    inv = CB.build_invariant(ENV_)

    # (1) 스케줄에 없는 노드 id. get_vtx 가 조용히 -1 을 돌려주는 자리.
    ghost    = CB.ActionID(typemax(Int) - 7)
    ghost_cs = CB.LinearConstraint([(1.0, CB.VarRef(:tF, ghost, nothing))], :le, 1.0)
    v1 = CB.verify(_prop(ghost_cs), ENV_, inv)
    @test v1 isa CB.Reject
    @test v1.reason === :unresolvable_reference
    @test occursin("not a schedule vertex", v1.detail)

    # (2) 🔴 실제로 도달 가능한 사례 — AGENTS 목록의 id 를 t0/tF 에 쓴 경우.
    #     `_default_id_resolver`(replan.jl:1146-1157)가 그 문자열을 RobotID 로 **정상 해석**하므로
    #     파싱은 통과하고, 예전 코드에서는 컴파일에서 터져 시뮬 루프까지 풀려 올라갔다.
    rid = first(sort!([CB.entity(CB.get_node_from_id(SCHED, CB.get_vtx_id(SCHED, v))).id
                       for v in Graphs.vertices(SCHED)
                       if CB.get_node_from_id(SCHED, CB.get_vtx_id(SCHED, v)) isa CB.RobotStart];
                      by = string))
    @test CB.get_vtx(SCHED, rid) == -1              # 비퇴화: 로봇 id 는 정점 id 가 **아니다**
    agent_cs = CB.LinearConstraint([(1.0, CB.VarRef(:t0, rid, nothing))], :le, 1.0)
    v2 = CB.verify(_prop(agent_cs), ENV_, inv)
    @test v2 isa CB.Reject
    @test v2.reason === :unresolvable_reference

    # (3) 후보 배정 엣지가 아닌 (u,v) 를 :xa 로 지목 — Xa 는 formulate_milp 안에만 있으므로
    #     (2b) 접지 검사가 아니라 build **백스톱**이 잡는다. 그래도 결과는 Reject 다.
    bad_xa = CB.LinearConstraint([(1.0, CB.VarRef(:xa, NID_MAX, _nid_mid()))], :le, 1.0)
    v3 = CB.verify(_prop(bad_xa), ENV_, inv)
    @test v3 isa CB.Reject
    @test v3.reason === :ungrammatical
    @test occursin("compilation failed", v3.detail)

    # (4) Big-M 크기 가드 — 계수가 커지면 "완화된" 쪽이 완화가 아니게 되어 ∨ 가 ∧ 로 조인다.
    #     상수를 키우면 ForbidWindow 등가가 깨지므로, 계수 쪽을 거부한다.
    huge = CB.Disjunction(
        CB.LinearConstraint([(1.0e3, CB.VarRef(:tF, NID_MAX, nothing))], :le, 1.0),
        CB.LinearConstraint([(1.0,   CB.VarRef(:t0, NID_MAX, nothing))], :ge, 2.0))
    v4 = CB.verify(_prop(huge), ENV_, inv)
    @test v4 isa CB.Reject
    @test v4.reason === :unresolvable_reference
    @test occursin("Big-M", v4.detail)
    # 음성 대조: 같은 모양인데 계수만 정상이면 **통과한다**(가드가 전부를 막지 않는다)
    ok = CB.Disjunction(
        CB.LinearConstraint([(1.0, CB.VarRef(:tF, NID_MAX, nothing))], :le, 1.0),
        CB.LinearConstraint([(1.0, CB.VarRef(:t0, NID_MAX, nothing))], :ge, 2.0))
    @test CB.grammar_ground_check(_prop(ok), SCHED) === nothing

    # (5) 게이트를 **우회한** 내부 호출은 여전히 시끄럽게 죽는다. 이건 LLM 경로가 아니라
    #     "verify 를 안 거치고 컴파일러를 직접 부른 내부 버그" 의 자리다 — 거기서는 예외가 맞다.
    @test_throws Exception _count_added_constraints(ghost_cs)
end

# --- 엔진 내부 경로 회귀 (env 를 mutate 하므로 반드시 맨 마지막) ------------------
# `fault_robot_and_reassign!`(reassign.jl:353-395)은 내부에서 `ForbidAgent` 를 만들어
# `verify()` → `formulate_milp(extra_constraints=...)` 로 흘린다. 파서를 좁힌 것이 그
# 경로에 닿으면 안 된다. 여기서는 그 함수가 하는 일을 **비싼 풀이 직전까지** 재현한다.
#
# ⚠️ **왜 `fault_robot_and_reassign!` 을 통째로 부르지 않는가 — 실측.** t=0 에서 그 함수의
#    trial solve 는 후보 엣지 423 → 4187 로 늘어난 MIP(69114 행)를 푼다. `assignment_mode
#    = :greedy` 로 만든 env 에는 솔버 시간제한이 안 걸려 있어서(full_demo.jl:282 의 attribute
#    dict 는 MILP 모드에서만 채워진다) HiGHS 가 **68 초에 gap 92.5%** 로 수렴하지 않았다.
#    풀이 결과는 C2 의 변경과 무관하므로, 이 게이트는 **제약이 모델에 들어가는 데까지**만 잰다.
#
# 🔴 **`release_pending_assignments!` 를 먼저 부르는 것이 핵심이다** — 실측한 함정:
#    이 수술 없이 `ForbidAgent` 를 컴파일하면 14대 로봇 **전부 0행**이 나온다. 컴파일러가
#    후보(Big-M) 엣지만 금지하고 이미 존재하는 구조 엣지는 절대 안 건드리기 때문이다
#    (compiler.jl:58-64·77). 그래서 "0행" 은 버그가 아니라 **호출 순서의 계약**이고,
#    아래는 그 계약을 지킨 상태에서 0행이 아님을 단언한다.
@testset "🔴 엔진 내부 경로가 여전히 돈다 (회귀 · ForbidAgent 가 행을 낸다)" begin
    rids = sort!([CB.entity(CB.get_node_from_id(SCHED, CB.get_vtx_id(SCHED, v))).id
                  for v in Graphs.vertices(SCHED)
                  if CB.get_node_from_id(SCHED, CB.get_vtx_id(SCHED, v)) isa CB.RobotStart];
                 by = string)
    @test !isempty(rids)
    rid = first(rids)

    # 수술 전: 계약대로 0행이다(음성 대조 — 아래 양성이 우연이 아님을 보인다)
    CB.RESPEC_FROZEN[] = Set{CB.AbstractID}()
    CB.RESPEC_PINNED[] = Set{CB.AbstractID}()
    @test _count_added_constraints(CB.ForbidAgent(rid, 0.0)) == 0

    # reassign.jl:357-378 과 **같은 순서**로 준비한다
    inv = CB.build_invariant(ENV_)
    closed_ids = Set{CB.AbstractID}(CB.get_vtx_id(SCHED, v) for v in ENV_.cache.closed_set)
    active_ids = Set{CB.AbstractID}(CB.get_vtx_id(SCHED, v) for v in ENV_.cache.active_set)
    CB.RESPEC_FROZEN[] = closed_ids
    CB.RESPEC_PINNED[] = union(closed_ids, active_ids)
    removed = CB.release_pending_assignments!(ENV_, inv; faulted = rid)
    @test length(removed) >= 1                      # 비퇴화: 수술이 실제로 엣지를 풀었다

    nc0 = _nconstr(_build(nothing).model)            # 수술 뒤의 base (BASE_NC 는 수술 전 값이다)
    n   = _nconstr(_build(_prop(CB.ForbidAgent(rid, 0.0))).model) - nc0
    @info "release_pending_assignments! removed $(length(removed)) edge(s); " *
          "ForbidAgent($(rid)) -> $(n) rows"
    # 🔴 0행이면 "로봇을 제거했다" 고 믿는 조용한 no-op 이다 — 재배정이 아예 안 일어난다.
    @test n >= 1
    @test CB.referenced_ids(CB.ForbidAgent(rid, 0.0)) == (rid,)
end

# =============================================================================
# 🔴 끝에서 끝까지 — 해석 불가능한 참조가 **시뮬 루프를 무너뜨리지 않는다** (수정 라운드 2)
# -----------------------------------------------------------------------------
# 크래시 경로 실측(수정 전): `_var_of` 의 error() 가
#   formulate_milp → verify()(verifier.jl:107) → maybe_respecify!(replan.jl:953, **try 없음**)
#   → respec_step! → route_planning.jl:271 까지 풀려 올라간다.
# 즉 `Reject` 도 `engage_fallback!` 도 아니고 시뮬레이션 루프가 통째로 죽는다.
# 아래는 그 정확한 경로를 producer 로 태워서 **`:rejected` 라는 전이가 나오는지** 본다.
# env 를 mutate 하므로(engage_fallback!) 파일의 맨 마지막이다.
# =============================================================================
@testset "🔴 e2e: maybe_respecify! 가 :rejected 를 내고 시뮬이 살아남는다" begin
    rid = first(sort!([CB.entity(CB.get_node_from_id(SCHED, CB.get_vtx_id(SCHED, v))).id
                       for v in Graphs.vertices(SCHED)
                       if CB.get_node_from_id(SCHED, CB.get_vtx_id(SCHED, v)) isa CB.RobotStart];
                      by = string))
    bad = CB.RespecProposal(CB.ConstraintSpec[
              CB.LinearConstraint([(1.0, CB.VarRef(:t0, rid, nothing))], :le, 1.0)])

    CB.push_ood!("robot $(rid) reported something the model answered with a bad reference")
    status = CB.maybe_respecify!(ENV_, CB.RESPEC_QUEUE; producer = (e, ev) -> bad)
    @test status === :rejected                 # 예외가 아니라 **전이**가 나왔다
    @info "e2e maybe_respecify! -> $(status)"

    # 그리고 루프가 실제로 계속 돈다 — 수정 전이라면 위 줄에서 이미 예외로 여기 못 온다.
    CB.step_environment!(ENV_)
    CB.update_planning_cache!(ENV_, 0.0)
    @test true
end
