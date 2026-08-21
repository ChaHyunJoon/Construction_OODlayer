# =============================================================================
# tools/monitor/gen_ng2_ranks.jl — 게이트 N-G2 의 짝 데이터 **생산 가능성 프로브**.
#
#   julia +lts --project=. tools/monitor/gen_ng2_ranks.jl
#
# 🔴 **이 스크립트는 `results/smdp/arm_ranks.json` 을 만들지 않는다. 만들 수 없다는 것을
#    실측으로 보이고 그 측정을 남긴다.** 왜 그렇게 하는지가 이 파일의 전부다.
#
# N-G2 가 묻는 것(설계 §11-3 / N-4-4): **`T_plan` 의 편향이 팔 간 비교를 뒤집는가.**
# 그 질문에 답하려면 사건마다 팔별 점수가 두 벌(경량·무거운) 있어야 하고, 팔별 점수를
# 내려면 `(s, a) → s⁺` 가 있어야 한다. 그것이 **Task T13 의 생성 시뮬레이터**이고 이
# 브랜치에는 없다. 여기서 그것을 즉흥으로 만드는 것은 계획서가 금지한 것이고
# ("이 태스크에서 즉흥적으로 모델을 늘리지 않는다"), 만들면 게이트가 **자기가 판정할
# 전이함수를 스스로 정의**하게 된다 — T9 이 ρ 에 대해 거부한 것과 같은 자기충족이다.
#
# 그래서 이 파일은 **없는 짝을 지어내는 대신, 지어내도 소용없는 이유를 잰다**:
#
#   측정 1. `T_plan_next` · `T_done` 의 **read-set**. `s.fleet` 과 `s.geo` 를 아무렇게나
#           흔들어도 두 함수가 **비트 동일**한가. 그렇다면 `s.fleet`/`s.geo` 에만 흔적을
#           남기는 팔은 `T_plan` 에게 **보이지 않는다** — 그 팔들 사이에서는 "T_plan 의
#           편향이 순위를 뒤집는다" 가 애초에 정의되지 않는다.
#   측정 2. 팔이 `s` 에 남기는 흔적(설계가 이미 못박은 것, 이 파일이 정하는 것이 아니다):
#             · NOOP         — 없음
#             · Replace      — `fleet[k].usage_s` 가 0 으로(새 로봇에 `_hz_ensure!` 가 0.0)
#             · SwapBattery  — 🔴 **없음**(배송이 뜨는 중이라 결정 직후 `s` 에 흔적이 없다.
#                              `.claude/CLAUDE.md` 가 이것을 **트립와이어**로 적어 뒀다)
#             · RelocateBuild— `geo.poses`
#           ⇒ 측정 1 이 참이면 넷 중 **넷 다** `T_plan` 에게 같은 값을 준다.
#
# 결과는 `results/smdp/arm_ranks_probe.json` 으로 남는다. **이름이 다른 이유가 그것이다** —
# 게이트가 먹는 파일과 헷갈리면 안 된다. 게이트는 짝이 없으면 죽고, 죽으면서 T13 을 가리킨다.
# =============================================================================
using ConstructionBots
import Random, Graphs
import JSON3
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
CB.include(joinpath(pkgdir(CB), "src", "smdp", "mdp.jl"))

# 🔴 **세계 지문(world fingerprint).** `nondeterminism-investigation.md` 가 규명한 대로, CB 를
#    재precompile 하면 `TypeName.hash` 가 다시 굴러 모든 ID 타입의 `hash`/`objectid` 가 바뀌고
#    배정 DAG 가 갈린다. 즉 **이 값이 같으면 두 실행이 같은 세계**다. ρ 적합과 N-G1 재검이
#    "같은 디렉토리·같은 세션" 이라는 주장을 산문이 아니라 **이 숫자**로 남긴다.
const WORLD_FP = hash(CB.ObjectID(1))
@info "세계 지문" hash_ObjectID_1=WORLD_FP pkgdir=pkgdir(CB)


# --- 씬 (SCENE-INCANTATION.md 정본) ------------------------------------------
env = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "ng2probe",
                         num_robots = 6, assignment_mode = :greedy,
                         n_spare_per_pool = 2,
                         open_animation_at_end = false, save_animation = false,
                         write_results = false, return_env_before_sim = true,
                         rng = Random.MersenneTwister(1))
CB.enable_battery!(env)
CB.enable_hazard!(env; seed = 7)

# 🔴 프로브 스텝을 **발견**한다(SCENE-INCANTATION §2 — 인용하지 않는다).
function discover_probe(env, maxstep::Int)
    for k in 1:maxstep
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0); CB.set_sim_step!(k)
        s  = CB.simstate_of(env)
        Δ  = CB.T_plan_next(s, env)
        if length(s.fleet) >= 2 && !isempty(CB.active_of(s)) && isfinite(Δ) && Δ > 0.0
            return (k, s)
        end
    end
    return (0, nothing)
end
const PROBE, S0 = discover_probe(env, 320)
PROBE > 0 || error("gen_ng2_ranks: 320 스텝 안에 비퇴화 스텝이 없다")
@info "N-G2 프로브 스텝(발견)" step=PROBE n_fleet=length(S0.fleet) n_active=length(CB.active_of(S0)) T_plan_next=CB.T_plan_next(S0, env) T_done=CB.T_done(S0, env) rho=CB.RHO[]

# --- 측정 1: T_plan 의 read-set ----------------------------------------------
"`fleet` 을 통째로 다른 값으로 바꾼 `s`(멤버십은 유지 — 그건 별개의 축이다)."
function perturb_fleet(s::CB.SimState; soc::Float64, usage::Float64)
    fl = Dict{Int,CB.RobotRec}()
    for k in sort!(collect(keys(s.fleet)))
        fl[k] = CB.RobotRec(soc = soc, usage_s = usage)
    end
    return CB.SimState(g = s.g, geo = s.geo, fleet = fl, prog = s.prog)
end

"`geo.poses` 를 전부 옮긴 `s` (= `RelocateBuild`/`TranslateBuild` 가 남기는 흔적의 모양)."
function perturb_geo(s::CB.SimState; dx::Float64)
    poses = Dict{Int,NTuple{3,Float64}}()
    for k in sort!(collect(keys(s.geo.poses)))
        p = s.geo.poses[k]
        poses[k] = (p[1] + dx, p[2] + dx, p[3])
    end
    return CB.SimState(g = s.g, geo = CB.GeoBlock(poses = poses, zones = s.geo.zones),
                       fleet = s.fleet, prog = s.prog)
end

const BASE_TPN = CB.T_plan_next(S0, env)
const BASE_TD  = CB.T_done(S0, env)

variants = Dict{String,CB.SimState}(
    "fleet_soc0_usage0"       => perturb_fleet(S0; soc = 0.0,  usage = 0.0),
    "fleet_soc1_usage0"       => perturb_fleet(S0; soc = 1.0,  usage = 0.0),      # ≈ Replace 흔적
    "fleet_soc1_usage_big"    => perturb_fleet(S0; soc = 1.0,  usage = 1.0e5),
    "geo_shift_100m"          => perturb_geo(S0; dx = 100.0),                     # ≈ RelocateBuild 흔적
)
invariant = Dict{String,Bool}()
for name in sort!(collect(keys(variants)))
    sv = variants[name]
    tpn, td = CB.T_plan_next(sv, env), CB.T_done(sv, env)
    same = (tpn === BASE_TPN) && (td === BASE_TD)
    invariant[name] = same
    @info "N-G2 측정 1 — T_plan read-set" variant=name T_plan_next=tpn T_done=td bit_identical_to_base=same
end

# 🔴 음성 대조: **read-set 안**에 있는 것을 흔들면 값이 **반드시** 달라져야 한다.
#    안 달라지면 위의 "비트 동일" 은 read-set 의 증거가 아니라 함수가 상수라는 증거다.
const CLOSED_MORE = let
    act = sort!(collect(CB.active_of(S0)))
    isempty(act) && error("gen_ng2_ranks: 활성이 비어 있다")
    CB.SimState(g = S0.g, geo = S0.geo, fleet = S0.fleet,
                prog = CB.ProgBlock(closed = union(S0.prog.closed, Set([first(act)]))))
end
const CTRL_TPN = CB.T_plan_next(CLOSED_MORE, env)
const CTRL_TD  = CB.T_done(CLOSED_MORE, env)
const CTRL_MOVED = (CTRL_TPN !== BASE_TPN) || (CTRL_TD !== BASE_TD)
@info "🔴 N-G2 음성 대조 — prog.closed(= read-set 안)를 흔들면 값이 움직이는가" T_plan_next=CTRL_TPN T_done=CTRL_TD moved=CTRL_MOVED base_T_plan_next=BASE_TPN base_T_done=BASE_TD
CTRL_MOVED ||
    error("gen_ng2_ranks: read-set 안을 흔들어도 T_plan 이 안 움직인다 — 위의 '비트 동일' 은 " *
          "read-set 의 증거가 아니라 함수가 납작하다는 증거다. 이 프로브는 무효다")

const ALL_INVARIANT = all(values(invariant))

# --- 측정 2: 사건 하나에서 팔별 점수를 실제로 매길 수 있는가 -------------------
#   `T_plan` 이 `s.fleet`·`s.geo` 를 안 읽으면, 그 둘에만 흔적을 남기는 팔들은 **같은 점수**를
#   받는다. 그러면 N-G2 의 τ 는 팔 순위가 아니라 **동점 규칙**을 재게 된다 — 게이트가 거부하는
#   바로 그 산출물이다(`gate_ng2.py` 의 RESOLUTION 검사, `test_gate_ng2.py` 가 실측).
arm_traces = [
    ("0", "NOOP",          "none"),
    ("1", "Replace",       "fleet.usage_s (→0 on the fresh body; .claude/CLAUDE.md)"),
    ("2", "RelocateBuild", "geo.poses"),
    ("3", "SwapBattery",   "none (delivery in flight; CourierRec was deleted — CLAUDE.md tripwire)"),
]
scores_if_scored_by_T_plan = Dict(a[1] => BASE_TD for a in arm_traces)   # 전부 같은 값이다
n_distinct = length(unique(values(scores_if_scored_by_T_plan)))
@info "🔴 N-G2 측정 2 — T_plan 으로 팔을 매기면 몇 개로 갈리는가" n_arms=length(arm_traces) n_distinct_scores=n_distinct all_tied=(n_distinct < 2)

out = Dict(
    "produced_arm_ranks" => false,
    "why" => "N-G2 requires per-arm scores in two lanes; that requires (s,a) -> s⁺, which is " *
             "Task T13's generative simulator and does not exist on this branch. This probe " *
             "measures why fabricating it would not help either.",
    "meta" => Dict("vocab" => "see wm4spacecraft_manufacturing/core/action_registry.json",
                   "probe_step" => PROBE, "rho" => CB.RHO[],
                   "n_fleet" => length(S0.fleet), "n_active" => length(CB.active_of(S0))),
    "measurement_1_T_plan_read_set" => Dict(
        "base_T_plan_next" => BASE_TPN, "base_T_done" => BASE_TD,
        "bit_identical_under" => Dict(k => invariant[k] for k in sort!(collect(keys(invariant)))),
        "all_invariant" => ALL_INVARIANT,
        "negative_control_prog_closed_moves_it" => CTRL_MOVED,
        "control_T_plan_next" => CTRL_TPN, "control_T_done" => CTRL_TD),
    "measurement_2_arm_traces" => [Dict("id" => a[1], "name" => a[2], "trace_in_s" => a[3])
                                   for a in arm_traces],
    "measurement_2_n_distinct_T_plan_scores" => n_distinct,
)
outdir = joinpath(pkgdir(CB), "results", "smdp")
mkpath(outdir)
open(joinpath(outdir, "arm_ranks_probe.json"), "w") do io
    JSON3.write(io, out)
end

@warn """
🔴 N-G2: `results/smdp/arm_ranks.json` 을 **만들지 않았다.** 측정은 남겼다
   (`results/smdp/arm_ranks_probe.json`).

   측정 1: `T_plan_next`/`T_done` 이 `s.fleet`·`s.geo` 에 대해 비트 동일 = $(ALL_INVARIANT)
           (음성 대조: `prog.closed` 를 흔들면 움직인다 = $(CTRL_MOVED))
   측정 2: 그 read-set 아래에서 네 팔의 `T_plan` 점수가 갈리는 개수 = $(n_distinct)

   ⇒ 팔별 점수를 내려면 `(s, a) → s⁺` 가 필요하고 그것은 **Task T13** 이다. 여기서 지어내면
     게이트가 자기가 판정할 전이함수를 스스로 정의하게 된다. 짝이 없으면 게이트는 죽는다 —
     그게 옳은 동작이고 `test_gate_ng2.py::test_missing_ranks_artifact_names_its_producer`
     가 그것을 못박는다.
"""
