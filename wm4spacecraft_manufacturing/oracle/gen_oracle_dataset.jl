# =============================================================================
# gen_oracle_dataset.jl -- E1 offline data-dump seam.
#
# Generalizes gen_oracle_fullsim.jl from a single fault-OOD sweep into the E1 dataset generator:
# for MANY instances (OOD kind x severity x seed x spare-provisioning), it
#   (1) CAPTURES the decision-time STATE FEATURES at the studied OOD event (the same public info the
#       LLM/surrogate reads), and
#   (2) SWEEPS every candidate DSL macro through the production run_one and records its realized
#       RunMetrics labels (complete / closed / total / realized makespan / feasible),
# then writes one JSONL row per (instance, macro). Python (E1-c) loads this to train a feature model
# and measure decision regret / ranking fidelity vs the ORACLE-best macro (feasibility-lexicographic).
#
# The surrogate has something to learn ONLY if the oracle-best macro VARIES across instances. Sources
# of variation here: OOD KIND (fault->Replace, zone->ForbidZone, battery-deep->Replace / battery-mild
# ->Deprioritize) and SPARE PROVISIONING (few spares -> Replace wedges, so NOOP can win). Both are
# encoded as state features (kind one-hot, soc, spare_count), so a state-reading model can beat any
# "always pick macro X" baseline. That gap is exactly the E1 signal.
#
# Run (from ConstructionBots.jl repo root):
#   julia +lts --project=. ../wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl
# Env: DS_SEEDS="1,2,3"  DS_KINDS="fault,zone,battery"  DS_SPARES="1,3,6"  DS_NOPROG=8000
#      DS_OUT=<path.jsonl>  DS_SMOKE=1 (1 instance only)
# =============================================================================
#
# ── 한국어 설명 (처음 읽는 사람을 위한 안내) ────────────────────────────────
# 이 파일이 하는 일: E1 실험용 "오프라인 데이터 덤프" 단계.
#   · 다양한 상황(instance)을 만든다 = OOD 종류 × severity(심각도) × seed(난수씨앗) × 예비로봇 수(spare).
#   · 각 상황에서 OOD 사건이 터진 그 순간의 "상태 특징(state features)"을 기록한다
#     (= LLM/surrogate 가 실제로 볼 수 있는 공개 정보와 동일한 것).
#   · 그리고 후보 DSL 매크로(NOOP/Replace/Deprioritize/ForbidZone/ReformTeam)를 하나씩
#     진짜 시뮬레이터에 넣어 끝까지 돌려보고, 그 실제 결과(완주 여부·makespan 등)를 정답(oracle) 라벨로 남긴다.
#   · 결과는 (instance, macro) 한 쌍당 JSONL 한 줄로 저장 → 나중에 파이썬이 이걸로 surrogate 를 학습.
# 프로젝트 안에서의 역할: surrogate(값싼 대리모델)를 학습시킬 "정답 데이터셋"을 만드는 생산기.
#   surrogate 가 배울 게 있으려면 "정답 매크로가 상황마다 달라져야" 한다 → 그 변동을 일부러 만들어 넣는 파일.
#
# 문법 참고 (Julia 초심자용, 이 파일에서 자주 나오는 비직관적 문법):
#   · f(x::T)          : x 가 타입 T 일 때만 쓰이는 메서드 정의(다중 디스패치). 같은 이름을 타입만 바꿔 여러 번 정의 가능.
#   · ::Int, ::Symbol  : "이 인자는 이 타입" 이라는 타입 표시.
#   · :fault, :zone    : 콜론으로 시작하면 Symbol(가벼운 이름표 상수). 문자열보다 빠른 비교용.
#   · foo!(...)        : 이름 끝의 `!` = 인자를 직접 바꾼다(in-place)는 관례.
#   · @printf, @__DIR__: `@`로 시작하면 매크로(컴파일 시점에 코드를 펼침). @__DIR__ = 이 파일이 있는 폴더 경로.
#   · Ref(x)           : "한 칸짜리 상자". FEAT[] 처럼 `[]` 로 안의 값을 읽고/쓴다(전역 가변 상태 저장용).
#   · (env, ev) -> ... : 익명함수(람다). arg 를 받아 화살표 뒤 식을 돌려준다.
#   · f() do x ... end : do-블록. 마지막 줄의 함수에 "첫 인자로 이 블록을 넘긴다"는 축약(all(...) do b ... 등).
#   · [x for x in xs]  : comprehension(리스트 내포). xs 를 훑어 새 배열을 만든다.
#   · try ... catch; d end : 오류가 나면 조용히 d 를 대신 반환(방어적 코드). 이 파일에 아주 많이 나옴.
#   · cond && expr     : cond 가 참일 때만 expr 실행(짧은 if 대용). cond || expr 은 그 반대.
# ────────────────────────────────────────────────────────────────────────────
import ConstructionBots as CB                     # 시뮬레이터 본체를 CB 라는 짧은 이름으로 불러옴
import HiGHS, Logging, Random, Graphs             # HiGHS = MILP 풀이 솔버, Graphs = 스케줄을 그래프로 다룸
using Printf                                       # @printf(형식화 출력)를 쓰기 위함

# 이 파일이 의존하는 보조 코드들을 include(그 파일 내용을 여기에 그대로 붙여넣어 실행).
# decpomdp/examples was deleted from the checkout. The only symbols the generator used from it were the
# 4 MDP-adapter fns (event_context/valid_actions/canonical_action/action_to_proposal); they are rebuilt
# on surviving CB code in ood_mdp_shim.jl (sibling of this file). See that file's header for the mapping.
include(joinpath(@__DIR__, "ood_mdp_shim.jl"))    # was: decpomdp/examples/ood_env.jl + ood_env_mdp.jl
# navigator.jl 은 CB 모듈 안에서 include 해야 함(world-age 문제 회피: 런타임에 정의되는 함수들이라 CB 스코프 필요).
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))   # fault_action / zone_action / battery (world-age)
# MDP STEP 1 의 확률적 고장 프로세스. DS_MC_K=1(기본)이면 절대 켜지지 않으므로 기존 실행은 불변.
CB.include(joinpath(pkgdir(CB), "src", "mdp", "mdp.jl"))

# MILP(작업배정 최적화) 솔버를 HiGHS 로 지정하고 옵션을 건다.
CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 60.0, "mip_rel_gap" => 0.05,   # 60초 제한 / 5% 오차 허용(속도↑)
    "output_flag" => false, "presolve" => "on")

# ---- config ----------------------------------------------------------------------------
# 아래 상수들은 전부 환경변수(ENV)로 덮어쓸 수 있음. get(ENV,"이름",기본값) = 환경변수 없으면 기본값 사용.
const SEEDS  = [parse(Int, s) for s in split(get(ENV, "DS_SEEDS", "1,2,3"), ",")]   # "1,2,3" → [1,2,3] (난수 씨앗 목록)
const KINDS  = [Symbol(s) for s in split(get(ENV, "DS_KINDS", "fault,zone,battery"), ",")]   # 생성할 OOD 종류들(Symbol로)
const SPARES = [parse(Int, s) for s in split(get(ENV, "DS_SPARES", "3"), ",")]   # n_spare_per_pool levels (fault only varies this)
const NOPROG = parse(Int, get(ENV, "DS_NOPROG", "8000"))     # no-progress cap: lower = faster data-gen, coarser stall labels
const SMOKE  = get(ENV, "DS_SMOKE", "0") == "1"              # smoke=참이면 딱 1개 instance만 돌려 빠르게 점검
const MACROS = [0, 1, 2, 3, 4, 8]                             # NOOP, Replace, Deprioritize, ForbidZone, ReformTeam, SwapBattery
# 8 = SwapBattery(현장 배터리 교체). battery 사건에서만 valid 이므로 다른 kind 에서는 valid_actions 가
# 걸러 NOOP 팔로 무너진다(action_to_proposal). VALID_ONLY 모드에서는 valid_mask 가 알아서 고른다.
const ACTION_NAME = Dict(0=>"NOOP", 1=>"Replace", 2=>"Deprioritize", 3=>"ForbidZone", 4=>"ReformTeam",
    # 조합 팔(ood_mdp_shim.jl 의 COMBO_IDS). DS_COMBO_ARMS=1 일 때만 요청될 수 있다.
    # 이 항목이 없으면 시뮬은 정상인데 **행을 쓰는 순간** KeyError 로 죽는다(2026-08-02 실측).
    5=>"ForbidAgent+ReformTeam", 6=>"Deprioritize+ForbidWindow",
    # 8 = SwapBattery : 같은 본체에 배터리만 현장 교체. Replace(1)와 달리 창고 "본체"를 안 먹는다
    #     — 두 팔의 소모 자원이 다르다는 것이 이 팔을 따로 두는 이유다(spec_dsl.jl SwapBattery).
    8=>"SwapBattery",
    # 7 = RelocateBuild(빌드 전체 평행이동). zone 사건의 **기본 개입 팔**로 3(ForbidZone)을 대체한다 —
    # 3 은 closed≈46 이후 도메인이 비어 NOOP 과 바이트 동일해지기 때문(ood_mdp_shim.jl `_zone_arms` 주석).
    7=>"RelocateBuild")   # 매크로 번호→이름
const OUTFILE = get(ENV, "DS_OUT", joinpath(@__DIR__, "out", "oracle_dataset.jsonl"))   # 결과 JSONL 저장 경로

# =========================================================================================
#  MDP STEP 2/3 : K-rollout 몬테카를로 라벨 + valid-macro-only 라벨링
#  (설계: ../MDP_DESIGN_FROM_SCRATCH.md §7.1 / §14)
# -----------------------------------------------------------------------------------------
#  DS_MC_K = 1 (기본)  -> 이 블록은 전부 무동작. 위험 프로세스가 켜지지 않고 매크로도 5개 전부
#                         돌므로 **기존 덤프와 바이트 단위로 동일한 경로**다.
#  DS_MC_K = K > 1     -> 각 (instance, macro) 를 K 번 굴린다. 매 판마다 "연구 대상 사건이 터진
#                         바로 그 순간"에 위험 시계를 arm 하므로, 결정 이전 궤적은 모든 rollout·
#                         모든 매크로에서 동일하고 결정 이후 미래만 표집된다(= Q(s,ω) 의 조건).
#                         rollout 마다 JSONL 한 줄을 쓰고, Q̂/SE/P(complete) 집계는 파이썬에서 한다
#                         (append-only 라 중단·재개가 안전하고 기존 분석 경로도 그대로 동작).
#  DS_VALID_ONLY = 1   -> 그 사건에서 애초에 실행 가능한 매크로만 라벨링한다(fault [0,1] /
#                         battery [0,1] 또는 [0,2] / zone [0,3]). 배포 경로가 어차피 valid 게이트를
#                         거치므로 무효 팔의 Q 는 결정에 쓰이지 않는다. 5팔 -> 2팔 = compute 60% 절감.
#                         valid 목록은 사건이 터져야 알 수 있으므로, **첫 판(NOOP)에서 관측한
#                         valid_mask** 를 그 instance 의 라벨 대상으로 삼는다.
const MC_K       = parse(Int, get(ENV, "DS_MC_K", "1"))
const HZ_SEED0   = parse(Int, get(ENV, "DS_HZ_SEED0", "1000"))
const VALID_ONLY = get(ENV, "DS_VALID_ONLY", "0") == "1"
const HZ_PARAMS  = CB.HazardParams(
    mtbf_break_s = parse(Float64, get(ENV, "DS_MTBF_BREAK", "500.0")),
    mtbf_cell_s  = parse(Float64, get(ENV, "DS_MTBF_CELL",  "500.0")),
    mtbf_zone_s  = parse(Float64, get(ENV, "DS_MTBF_ZONE",  "Inf")),
    drain_sigma  = parse(Float64, get(ENV, "DS_DRAIN_SIGMA", "0.15")),
    fire_safe_target = true, fire_require_spare = true,
    fire_obstacle = false,
    fire_clear = !(get(ENV, "DS_HOTSWAP", get(ENV, "HOT_SWAP", "0")) == "1"),
    max_events = parse(Int, get(ENV, "DS_MAX_EVENTS", "12")))
# fault OOD 를 "몇 개 노드가 닫혔을 때" 터뜨릴지 시점 목록. 환경변수 없으면 (12,20,30,45,60) 기본값.
_fire_fault() = (pts = get(ENV, "DS_FIRE_FAULT", ""); isempty(pts) ? (12,20,30,45,60) :
                 Tuple(parse(Int, strip(s)) for s in split(pts, ",")))
# OOD 종류마다 "발화 시점(closed 노드 수)" 목록. 같은 진행도에서 터지게 해 공정 비교(timing 단서 제거) 목적.
const FIRE_POINTS = Dict(:fault => _fire_fault(), :zone => (12,20,30),
                         :battery => (12,20,30), :zoneblk => (8,14,20,28),
                         :faultidle => (12,20,30,45,60), :zoneharm => (8,14,20,28),
                         :zonecore => (8,14,20,28))

# =========================================================================================
#  DS_FIRE_GRID : 발화 시점을 **instance 차원**으로 올린다 (2026-08-04)
# -----------------------------------------------------------------------------------------
# 문제. 위의 FIRE_POINTS 는 grid 가 아니라 **재시도 사다리**다. 한 instance 에 같은 액션을 여러
# 시점에 예약해 두고 `fired[]` 플래그로 첫 성공만 남긴다. 그런데 tractor 는 첫 시뮬 배치에서 이미
# ~58 노드를 닫으므로 (12,20,30,45,60) 이 **전부 같은 순간에 due** 가 되어 실제 발화점이 하나로
# 붕괴한다. 실측: openworld_merged.jsonl 60 instance 의 closed_at_fire ∈ {50,58} 뿐이고
# progress 의 sd 는 0.005 다.
#
# 그 대가. novelty 교정( export_novelty_calibration.py )이 그 덤프로 mu/sd 를 맞추므로 `progress`
# 축이 사실상 점 하나가 된다. 배포 데모처럼 중반(progress 0.41)에 터지는 battery 는 z=45 → cap(8)
# 로 잘려도 6축 중 혼자 score 의 93% 를 차지해, **종류와 무관하게 novel** 로 판정된다. 즉 라우터가
# "아는 종류인가"가 아니라 "교정과 같은 순간에 터졌나"를 재고 있었다.
#
# 고침. DS_FIRE_GRID 에 목표 발화점을 주면 그 값 하나가 instance 의 5번째 차원이 되고, instance id
# 에 `_f<closed>` 가 붙는다. 각 instance 안에서는 여전히 사다리를 쓰되 **목표점 위쪽으로만** 짧게
# 재시도한다(DS_FIRE_RETRY 간격 × DS_FIRE_TRIES 회): 그 진행도에 안전한 fault 대상이 없으면 조금
# 뒤에 다시 시도하되, 다른 진행도로 새어나가지는 않게 한다.
#
# 하위호환. DS_FIRE_GRID 가 비어 있으면(기본) fire_at=0 이 흘러 예전 사다리를 그대로 타고, iid 도
# 예전 문자열 그대로이며 `fire_target` 열도 붙지 않는다 = 기존 덤프/분석과 바이트 호환.
const FIRE_GRID  = [parse(Int, strip(s)) for s in split(get(ENV, "DS_FIRE_GRID", ""), ",")
                    if !isempty(strip(s))]
const FIRE_RETRY = parse(Int, get(ENV, "DS_FIRE_RETRY", "8"))    # 재시도 간격(닫힌 노드 수)
const FIRE_TRIES = parse(Int, get(ENV, "DS_FIRE_TRIES", "6"))    # 재시도 횟수(목표점 포함)

"목표 발화점 f 에 대한 짧은 재시도 사다리. f=0 이면 그 종류의 기존 FIRE_POINTS 를 그대로 쓴다."
fire_ladder(kind::Symbol, f::Int) =
    f > 0 ? Tuple(f + FIRE_RETRY * (i - 1) for i in 1:FIRE_TRIES) : FIRE_POINTS[kind]

"""
DS_MACROS="0" : 라벨링할 매크로를 제한한다(기본은 MACROS 전체).

왜 필요한가 -- novelty 교정은 **결정 순간의 상태 서술자만** 읽는다(`descriptors_from_row` 는 라벨을
쓰지 않는다). 그래서 교정을 고치는 데는 매크로 스윕이 필요 없고 판 하나면 충분하다. 6판 → 1판 =
같은 시간에 6배 많은 진행도를 덮을 수 있다. surrogate 재학습까지 하려면 이 옵션 없이(=전체 스윕)
다시 돌려야 한다 -- 그건 별개의 비용이고 여기서 숨기지 않는다.
"""
const MACRO_SUBSET = [parse(Int, strip(s)) for s in split(get(ENV, "DS_MACROS", ""), ",")
                      if !isempty(strip(s))]
const NOCTRL = get(ENV, "DS_NOCTRL", "0") == "1"

"""
사람이 읽는 instance id. fire_at>0 일 때만 `_f<closed>` 가 붙으므로, 예전 덤프의 id 와 충돌하지
않고 RESUME(이미 한 것 건너뛰기)도 진행도별로 따로 동작한다.
"""
instance_id(kind, severity, seed, n_spare, fire_at) =
    "$(kind)_s$(seed)_sev$(round(severity, digits = 2))_sp$(n_spare)" *
    (fire_at > 0 ? "_f$(fire_at)" : "")

# ---- GRADED severity (GRADED_OOD_DESIGN.md) ---------------------------------------------
# The generator kind is NOT what the row records. A harmless variant must carry the SAME `kind`
# label as its consequential sibling — otherwise the one-hot on `kind` determines the best macro
# again and the task stays trivial (H(best|kind)=0). The harmless/consequential distinction must be
# readable ONLY from state features (severity, agent_pending, soc, spare_count, zone geometry).
# row_kind : 생성용 세부 종류(:faultidle 등)를 "컨트롤러가 보는" 큰 종류 라벨로 뭉친다.
#   (해로운 변종 :faultidle 도 :fault 와 같은 "fault" 라벨을 달아야, kind 만 보고 정답을 못 맞히게 됨.)
#   삼항연산 a ? b : c 를 이어붙인 형태: k가 fault계열이면 "fault", zone계열이면 "zoneblk", 아니면 그대로.
#   :zonecore(root 목표를 삼키는 해로운 변종)도 **같은 "zoneblk" 라벨**을 단다 — 라벨이 갈리면
#   kind one-hot 이 다시 정답을 결정해 과제가 trivial 해진다. 차이는 오직 상태(zone_root_cover)로만 보여야 한다.
row_kind(k::Symbol) = k in (:fault, :faultidle)              ? "fault" :
                      k in (:zoneblk, :zoneharm, :zonecore)  ? "zoneblk" : String(k)

# A HARMLESS breakdown: fault a robot that owns NO pending work (it has delivered its last cargo and
# is driving clear). The event fires, the NL is identical, `agent_pending` is 0 -> a spare bought for
# it is pure waste, so NOOP is the correct macro. This is the within-`fault` restraint class.
# _pick_idle_victim : "해로운 고장" 데모용 — 지금 아무 pending 작업도 없는(=고장나도 무해한) 로봇을 하나 고른다.
#   env = 시뮬레이션 환경. 없으면 nothing 반환.
function _pick_idle_victim(env)
    sched = env.sched
    # robots that are inside an ACTIVE transport unit right now: they are CARRYING cargo. Killing one
    # collapses the build even though it owns no *pending* assignment, so it is not a harmless victim.
    carrying = Set{CB.RobotID}()                       # 지금 화물을 운반 중인 로봇 id 모음(무해 후보에서 제외)
    for v in env.cache.active_set                      # 현재 활성 노드들을 훑어
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        (n isa CB.TransportUnitGo || n isa CB.FormTransportUnit) || continue   # 운반 관련 노드만 관심
        for rid in keys(try CB.robot_team(CB.entity(n)) catch; Dict() end)     # 그 팀에 속한 로봇들을
            rid isa CB.RobotID && push!(carrying, rid)                         # carrying 집합에 등록
        end
    end
    # 앞으로 할 운반 일이 **하나라도** 남은 로봇들(= 무해 후보에서 반드시 빼야 하는 집합).
    #
    # [2026-08-05 수정] 예전에는 이 판정을 `_first_pending_assignment(env, rid) === nothing` 으로 했다.
    # 그 술어는 "지금 깨끗한 작업 경계에 서 있는가"를 묻는 것이지 "남은 일이 있는가"를 묻지 않는다.
    # 빌드가 굴러가면 로봇 대부분은 운반 사슬 안에 있어 그 술어가 nothing 을 돌려주므로, **바쁜 로봇이
    # 전부 '일 없음'으로 오분류**됐다. 그래서 faultidle 은 초반(closed=58)에만 무해했고 그 뒤로는
    # 실제로는 일감을 가진 로봇을 죽여 빌드를 세웠다 — 실측(firegrid_sfaultidle v1): f58 은 pending=0
    # 이라 NOOP 완주, f100~f260 은 pending=4/2/2/2/1 이고 NOOP 전부 미완주. 즉 "무해한 쌍둥이"라는
    # 이 변종의 존재 이유가 중반 이후 통째로 무너져 있었다(라벨은 상태와 일치하므로 틀리진 않았지만,
    # kind 안의 정답 다양성을 만들지 못한다).
    #
    # 올바른 판정은 스케줄 구조에서 직접 읽는다: **아직 안 닫힌 FormTransportUnit 팀의 멤버인가**.
    # 이것은 `pick_hotswap_fault_target` 의 후보 조건과 정확히 여집합이라, 두 변종이 같은 기준의
    # 반대편에 놓인다(해로운 = 남은 운반 있음 / 무해한 = 없음).
    busy = Set{CB.RobotID}()
    for v in Graphs.vertices(sched)
        v in env.cache.closed_set && continue
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.FormTransportUnit || continue
        for rid in keys(try CB.robot_team(CB.entity(n)) catch; Dict() end)
            rid isa CB.RobotID && push!(busy, rid)
        end
    end
    # (1) a WORKING robot that has run out of pending work AND is not carrying anything. Rare early in
    #     the build (every active robot still owns a chain), so this is normally only hit late.
    for v in env.cache.active_set
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        node isa CB.RobotGo || continue                # 이동 중인 로봇 노드만
        rid = try CB.entity(node).id catch; nothing end
        rid isa CB.RobotID || continue
        rid in carrying && continue                    # 운반 중이면 제외(무해하지 않음)
        rid in busy && continue                        # 앞으로 할 운반이 남았으면 제외(무해하지 않음)
        (try CB.is_spare(rid) || CB.is_recovery_spare(rid) catch; false end) && continue   # 예비/복구 로봇도 제외
        return rid                                     # 조건 통과 = 일 없는 일반 로봇 → 이걸 희생양으로
    end
    # (2) a STANDBY SPARE dies in its depot. A real breakdown alarm ("Robot Rn has broken down"), at
    #     the SAME build-progress points as the consequential faults — so `closed_at_fire` cannot be
    #     used as a shortcut — but it owns no work (`agent_pending = 0`), so intervening is waste and
    #     NOOP is correct. The model must read agent_pending/spare_count, not the kind or the timing.
    for rid in (try CB.active_spares() catch; CB.RobotID[] end)   # 대안: 창고에 서 있는 예비 로봇 하나
        (try CB.is_recovery_spare(rid) catch; false end) && continue   # 복구용 예비는 제외
        return rid
    end
    return nothing                                     # 무해한 희생양을 못 찾음
end

# fault_idle_action : 위에서 고른 무해한 로봇을 고장내는 "액션 함수"를 만들어 돌려준다(함수를 반환하는 함수).
#   obstacle=false, clear=true → 시신을 치워 장애물로 안 남게(순수 교체 시나리오).
fault_idle_action() = function (env)
    rid = _pick_idle_victim(env)
    rid === nothing && return nothing
    return CB.fault_action(; target = rid, obstacle = false, clear = true)(env)
end

# A HARMLESS zone: same event, same NL, same :zone classification -- but placed on OPEN FLOOR, clear of
# every staging circle. It blocks nothing, so restaging is wasted effort and NOOP is correct.
#
# (First attempt put it over an ALREADY-FINISHED staging circle. That never fired: at the shared fire
# points -- 8..28 closed nodes -- no assembly is finished yet. Firing it late WOULD work, but then
# `closed_at_fire` alone would separate harmless from consequential zones, handing the model a timing
# shortcut instead of forcing it to read the geometry. Open floor fires at the SAME progress points.)
# place_harmless_zone! : "무해한 zone"을 아무것도 막지 않는 빈 바닥에 놓는다(정답은 NOOP). NL 문자열을 반환.
#   key=이 zone의 이름표, rfrac=실제 staging 반지름 대비 크기 비율. env 를 직접 바꾸므로 이름 끝에 `!`.
function place_harmless_zone!(env; key::Symbol = :zoneharm, rfrac::Float64 = 0.8)
    isempty(env.staging_circles) && return nothing      # 놓을 기준(staging 원)이 없으면 포기
    balls = collect(values(env.staging_circles))         # 모든 staging 원(부품 대기 구역)들
    rref = maximum(Float64(CB.get_radius(b)) for b in balls) * rfrac * 0.5   # size-comparable to a real one
    cx   = maximum(Float64(CB.get_center(b)[1]) + Float64(CB.get_radius(b)) for b in balls)   # 가장 오른쪽 가장자리 x
    for step in 1:40                                    # walk outward until clear of every staging circle
        c = [cx + rref * (1.0 + 0.5 * step), 0.0]        # 오른쪽으로 점점 멀리 후보 중심점을 잡음
        clear = all(balls) do b                          # 모든 원 b 에 대해(do-블록이 all의 판정 함수)
            bc = Vector{Float64}(CB.get_center(b)[1:2])   # 원 b 의 중심(x,y)
            sqrt(sum((bc .- c) .^ 2)) > Float64(CB.get_radius(b)) + rref + 1.0   # b 와 겹치지 않으면 참
        end
        clear || continue                                # 하나라도 겹치면 더 바깥으로
        z = CB.add_restriction_zone!(key, c, rref)        # 겹침 없는 위치 확보 → 그 자리에 zone 생성
        nl = "A no-go exclusion zone has appeared at ($(round(c[1];digits=2)), $(round(c[2];digits=2))) " *   # LLM에게 줄 자연어 사건 설명
             "near a staging area; restage the affected assembly out of the restricted region."
        try CB.record_ood_truth!(nl, CB.ZoneTruth(key, c, Float64(CB.get_radius(z)), nothing)) catch end   # 정답 채점용 truth 기록
        return nl
    end
    return nothing
end

# TRUE severity of a zone event: how much of a PENDING staging circle the zone actually covers. This is
# the physical quantity that separates a consequential zone from a harmless one. Without it the only
# zone signals are `zone_radius` and the injector's own knob, and the two variants are indistinguishable
# to the model (or worse, separable only by a label-leaking artefact). 0 = blocks nothing.
# zone_overlap_frac : zone 이 "아직 안 끝난" staging 원을 얼마나 덮는지(0~1)를 계산 = zone 의 진짜 severity.
#   env, zkey(zone 이름표) → 가장 많이 겹치는 원의 겹침 비율. zone 없으면 -1, 아무것도 안 막으면 0.
function zone_overlap_frac(env, zkey)
    z = try CB.RESTRICTION_ZONES[][zkey] catch; nothing end
    z === nothing && return -1.0
    zc = Vector{Float64}(CB.get_center(z)[1:2]); zr = Float64(CB.get_radius(z))   # zone 의 중심/반지름
    best = 0.0
    for (aid, ball) in env.staging_circles              # 각 assembly 의 staging 원을 검사
        ac = try CB._assembly_complete_node(env, aid) catch; nothing end
        ac === nothing && continue
        v = try CB.get_vtx(env.sched, CB.node_id(ac)) catch; nothing end
        (v === nothing || v in env.cache.closed_set) && continue         # only PENDING staging areas
        bc = Vector{Float64}(CB.get_center(ball)[1:2]); br = Float64(CB.get_radius(ball))   # 원의 중심/반지름
        d = sqrt(sum((bc .- zc) .^ 2))                  # 두 원 중심 사이 거리
        d >= br + zr && continue                                         # disjoint
        # 두 원이 겹치는 면적(area) 계산 — if 가 값을 돌려주는 식으로 쓰임(Julia 에선 if도 표현식).
        area = if d <= abs(br - zr)
            π * min(br, zr)^2                                            # one circle inside the other
        else                                                             # circle-circle lens area
            a1 = acos(clamp((d^2 + zr^2 - br^2) / (2d * zr), -1.0, 1.0))   # 렌즈꼴 면적 공식(clamp=범위 잘라 수치안정)
            a2 = acos(clamp((d^2 + br^2 - zr^2) / (2d * br), -1.0, 1.0))
            zr^2 * (a1 - sin(2a1) / 2) + br^2 * (a2 - sin(2a2) / 2)
        end
        best = max(best, area / (π * br^2))              # (겹친 면적 / 원 전체 면적) 중 최댓값 유지
    end
    return best
end

# --- CONSEQUENTIAL zone injector ------------------------------------------------------------------
# random_restriction_zone! deliberately caps the radius so the zone is a harmless LOCAL detour (never
# swallows a goal region) -> inadmissible for the oracle. To make a zone that ForbidZone/restage MUST
# recover (so ForbidZone becomes oracle-best, a 2nd decision class vs fault->Replace), we place the
# zone ON a FUTURE assembly's staging circle: it overlaps that circle (=> zone_blocked_assemblies
# returns the assembly, so ForbidZone grounds) AND blocks that assembly's staging (=> NOOP leaves it
# unbuildable = consequential). Returns the NL event (classifies as :zone) or nothing if none blockable.
# place_blocking_zone! : "consequential(정말 막는) zone"을 미래 assembly 의 staging 원 위에 놓는다.
#   offset = 연속적 severity 손잡이(0=중심에 딱 얹어 막음 → ForbidZone이 정답 / 큼=가장자리로 비켜 안 막음 → NOOP이 정답).
#   막을 대상이 없으면 nothing, 있으면 NL 문자열 반환. env 를 바꾸므로 `!`.
function place_blocking_zone!(env; key::Symbol = :zoneblk, offset::Float64 = 0.0, rfrac::Float64 = 0.8)
    # Zone of radius `rfrac`*staging_radius, placed at `offset`*staging_radius AWAY from the staging
    # centre. `offset` is the CONTINUOUS severity knob (empirically a centred zone always blocks, so we
    # slide it toward the edge instead of shrinking it):
    #   * small offset (~0)  -> zone over the staging CENTRE -> staging blocked -> NOOP fails, ForbidZone
    #                           (restage) required  => ForbidZone is oracle-best.
    #   * large offset (>~1) -> zone off the edge -> robots stage in the clear part -> NOOP completes, and
    #                           an unnecessary ForbidZone-restage only adds makespan => NOOP is oracle-best.
    # The best macro FLIPS with `offset`, and near the flip both are close -> the graded, non-trivially
    # rankable signal the surrogate must read (`zone_radius` + the zone/target geometry).
    isempty(env.staging_circles) && return nothing
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))   # 가장 큰 원 = 빌드 중심(root)
    for (aid, ball) in env.staging_circles
        aid == root && continue                          # 중심 assembly 는 건드리지 않음
        ac = try CB._assembly_complete_node(env, aid) catch; nothing end
        ac === nothing && continue
        v = try CB.get_vtx(env.sched, CB.node_id(ac)) catch; nothing end
        v === nothing && continue
        (v in env.cache.closed_set || v in env.cache.active_set) && continue   # only FUTURE assemblies
        # ---- INJECTOR/REPAIRER ELIGIBILITY MATCH (DS_ZONE_ELIGIBLE) --------------------
        # The injector's eligibility test must match whatever the ARM actually enacts, or the
        # intervention is a guaranteed no-op and the instance is a manufactured tie.
        #
        #   "restageable" — matches macro 3 (ForbidZone -> restage_all_blocked!). That repairer
        #     additionally requires `!_assembly_started` (restage_assembly! refuses a started
        #     assembly with `:already_started`), which the AssemblyComplete test above is strictly
        #     weaker than. NOTE this filter makes zone events essentially UNFIREABLE mid-build:
        #     measured 2026-08-03 the restageable set is 7 at closed=0 and 0 from closed≈46 on.
        #     Kept only to reproduce the ForbidZone-era analysis.
        #   "workdisc"    — matches macro 7 (RelocateBuild -> translate_whole_build!). That repairer
        #     reads `_future_work_discs` (unfinished goals + non-root staging), gated on
        #     `closed_set` only, so the matched test is "does this zone actually overlap future
        #     work?" — checked AFTER placement against the live geometry, and rolled back if not.
        #     This is the default: it is the arm the generator now labels.
        #   "legacy"      — no extra filter (pre-2026-08-03 behaviour; DS_ZONE_RESTAGEABLE=0).
        elig = get(ENV, "DS_ZONE_ELIGIBLE",
                   get(ENV, "DS_ZONE_RESTAGEABLE", "1") == "0" ? "legacy" : "workdisc")
        if elig == "restageable"
            (try CB._assembly_started(env, aid) catch; false end) && continue   # 수리기가 옮길 수 있는 것만 대상으로
        end
        c = Vector{Float64}(CB.get_center(ball)[1:2]); r = Float64(CB.get_radius(ball))   # 대상 원의 중심/반지름
        # offset toward the root (build core) direction, so the zone slides off the staging area predictably
        rc = Vector{Float64}(CB.get_center(env.staging_circles[root])[1:2])   # 빌드 중심 방향으로
        dir = rc .- c; nd = sqrt(sum(dir .^ 2)); dir = nd > 1e-6 ? dir ./ nd : [1.0, 0.0]   # 그 방향 단위벡터(0나눗셈 방지)
        zc = c .+ (offset * r) .* dir                    # 중심에서 offset*r 만큼 그 방향으로 밀어 zone 중심 결정
        z = CB.add_restriction_zone!(key, zc, r * rfrac)  # zone 생성
        # workdisc 모드: 방금 놓은 구역이 **실제로** 미래 작업 원반과 겹치는지 살아있는 기하로 확인한다.
        # 안 겹치면 RelocateBuild 의 Δ 가 0 이라 NOOP 과 같아지므로, 구역을 되돌리고 다음 후보로 넘어간다.
        if elig == "workdisc"
            n_ov = try CB._count_future_work_overlaps(env; zone_keys = [key]) catch; -1 end
            if n_ov == 0
                CB.remove_restriction_zone!(key)          # 되돌림(다음 후보 시도) — 구역을 남기면 조용한 no-op 이 된다
                continue
            end
        end
        nl = "A no-go exclusion zone has appeared at ($(round(zc[1];digits=2)), $(round(zc[2];digits=2))) " *
             "near a staging area; restage the affected assembly out of the restricted region."
        try CB.record_ood_truth!(nl, CB.ZoneTruth(key, Float64[zc[1], zc[2]], Float64(CB.get_radius(z)), aid)) catch end   # truth 기록(대상 aid 포함)
        return nl
    end
    return nothing
end

# --- CORE zone injector: the HARM-carrying zone family (2026-08-03) ---------------------------------
# place_blocking_zone! above lands on a SUB-assembly's staging area, which the old guard
# (`zone_clears_root_goals`) required — the root's own delivery goals had to stay clear, because the
# only spatial repair then was `restage_all_blocked!`, which cannot move the root. The measured
# consequence: NOOP was never punished. Seed 301 closed exactly 213/313 at offset 0.0, 0.9 AND 1.3 —
# the severity knob moved the value of INTERVENING, never the damage of doing nothing, so the class
# could not express "you must react".
#
# RelocateBuild moves the root too, so the interesting family is now injectable: a zone that swallows
# a controlled FRACTION of the root's delivery goals (do-nothing cannot finish the final assembly)
# while a rigid whole-build shift clearing it still exists (RelocateBuild can). `frac` is the
# continuous severity: 0 -> one goal, 1 -> every root goal. `core_zone_for_severity` walks the
# coverage DOWN if the requested one is not escapable, and reports the coverage it actually used, so
# an injected core zone is recoverable BY CONSTRUCTION rather than by hope.
#
# row_kind(:zonecore) == "zoneblk" ON PURPOSE (see the GRADED severity note): the harmful and the
# harmless variant must wear the SAME controller-visible label, or the one-hot on `kind` decides the
# answer again and the task is trivial. The difference must be readable only from state — which is
# what the `zone_root_cover` column exists to carry.
function place_core_zone!(env; key::Symbol = :zonecore, frac::Float64 = 0.6)
    isempty(env.staging_circles) && return nothing
    sel = try CB.core_zone_for_severity(env, frac) catch; nothing end
    (sel === nothing || !sel.relocatable || sel.radius <= 0.0) && return nothing   # 복구 불가면 주입하지 않음
    zc = Vector{Float64}(sel.center)
    z = CB.add_restriction_zone!(key, zc, sel.radius)
    nl = "A no-go exclusion zone has appeared at ($(round(zc[1];digits=2)), $(round(zc[2];digits=2))) " *
         "over the central build area, covering $(sel.covered) of the $(sel.total) final-assembly " *
         "delivery points; the work region must be moved clear of the restricted region."
    # assembly = nothing : core zone 은 "막힌 조립체 하나"가 없다(빌드 코어 전체가 걸린다). RelocateBuild 는
    #   assembly 를 안 쓰므로 문제 없고, 오히려 root 를 지목하면 ForbidZone 이 잘못 grounding 될 수 있다.
    try CB.record_ood_truth!(nl, CB.ZoneTruth(key, Float64[zc[1], zc[2]], Float64(CB.get_radius(z)), nothing)) catch end
    return nl
end

"구역이 root 하역 목표를 삼킨 비율(0~1). 구역이 없으면 -1(파이썬 쪽이 '해당없음'으로 읽는 센티넬)."
# zone_overlap_frac 이 staging 원 겹침을 재는 것과 달리, 이건 **못 옮기는 root 목표**를 몇 개 삼켰나를 잰다.
# core zone 의 harm 은 여기에만 나타난다 — staging 겹침으로는 0 으로 보일 수 있다.
function zone_root_cover_frac(env, zkey)
    z = try CB.RESTRICTION_ZONES[][zkey] catch; nothing end
    z === nothing && return -1.0
    cov = try CB.root_goal_coverage(Vector{Float64}(CB.get_center(z)[1:2]),
                                    Float64(CB.get_radius(z)), env) catch; nothing end
    return cov === nothing ? -1.0 : Float64(cov.frac)
end

# ---- captured decision-time features (set once, at the studied OOD event) ---------------
# FEAT = 이번 instance 의 "결정 순간 특징"을 담아둘 전역 상자(한 번만 채워짐). NEV = 지금까지 본 OOD 이벤트 수.
const FEAT = Ref{Any}(nothing)
const NEV  = Ref(0)

# ---- natural-language observation of the event (the LLM's actual input channel) ---------
# WHY THIS EXISTS (added 2026-07-28)
#   The claim under test is "a genuinely NEW OOD is read by an LLM **from the natural-language
#   observation**, a FAMILIAR one is answered by the cheap surrogate". Measuring that honestly
#   requires the dump to carry the sentence the controller actually sees. Until now it did not:
#   the sentence was created at injection time and logged into OOD_TRUTH_LOG (ood_truth.jl) as the
#   `nl` half of the (nl, truth) pair, then thrown away. Feeding the LLM `kind=battery, soc=0.55`
#   instead is circular — it presupposes that a never-before-seen event was already parsed into the
#   existing schema, which is exactly the ability under test.
#
#   ONLY the `nl` half is copied. The `truth` half is the evaluator-only channel and must never
#   reach a producer's input (that would be answer leakage); see ood_truth.jl's two-channel rule.
# 자연어 사건 문장 저장(2026-07-28 추가). 주입 시점에 이미 만들어져 OOD_TRUTH_LOG 에 (nl, truth) 로
# 들어가 있는 문장 중 **nl(관찰) 쪽만** 가져와 덤프에 싣는다. truth(정답) 쪽은 절대 싣지 않는다(정답 누수).
function last_event_nl()
    try
        log = CB.ood_truth_log()
        isempty(log) && return ""
        return String(last(log).nl)                     # 가장 최근에 주입된 사건의 자연어 관찰
    catch
        return ""                                       # 로그가 없거나 형식이 다르면 조용히 빈 문자열
    end
end

# _agent_pending_tasks : 고장 대상 로봇이 아직 안 끝낸 "운반팀에 투입될 RobotGo" 작업 수(=피해 규모 대리지표). 대상 없으면 -1.
function _agent_pending_tasks(env, agent)
    agent === nothing && return -1
    sched = env.sched; n = 0
    for v in Graphs.vertices(sched)                     # 스케줄의 모든 노드를 훑어
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        (node isa CB.RobotGo && CB.bound_to_agent(node, agent)) || continue   # 이 agent 에게 묶인 이동 작업만
        v in env.cache.closed_set && continue           # 이미 끝난 건 제외
        outs = Graphs.outneighbors(sched, v); isempty(outs) && continue       # 다음 작업이 없으면 제외
        CB.get_node_from_id(sched, CB.get_vtx_id(sched, outs[1])) isa CB.FormTransportUnit || continue   # 다음이 운반팀 형성인 것만
        n += 1
    end
    return n
end

# =========================================================================================
#  RAW STATE DUMP  --  덤프는 원자료로, 서술자는 파이썬에서.
# =========================================================================================
# WHY RAW. The state descriptor set is still moving (fleet_soc_p25 / work_energy_mismatch /
# staging_conflict / stalled_frac are new, and each is a candidate, not a decision). Baking a
# formula into a multi-hour labelling run means any redefinition throws the run away. Dumping the
# RAW quantities instead makes every descriptor a PYTHON RECOMPUTE, never a re-simulation.
#
# Emitted as PARALLEL VECTORS keyed by integer robot/assembly id, because the JSONL writer here
# handles vectors but not dicts, and because an integer key joins cleanly on the Python side (the
# same id appears as RobotID/BotID depending on the call site -- matching on `.id` avoids that).
#
# [한국어] 서술자 정의가 아직 바뀌는 중이므로 계산식을 굽지 않고 원자료만 남긴다. 그러면 서술자를
#   몇 번을 바꾸든 재시뮬이 아니라 재계산이면 된다. Dict 는 이 파일의 JSON 작성기가 못 다루므로
#   "정수 id 기준 평행 벡터"로 내보낸다(호출 지점마다 RobotID/BotID 로 달라 보이는 문제도 함께 회피).
_idint(x) = try Int(getproperty(x, :id)) catch; -1 end

# -----------------------------------------------------------------------------------------
#  X_C (커밋먼트) + X_G (기하) 원자료  — 2026-08-02 추가
# -----------------------------------------------------------------------------------------
# 왜 추가하는가: 96 인스턴스 T1 에서 φ 가 **완주 여부조차** 다수결 기준선만큼밖에 못 맞혔다
# (0.755 vs 0.745). 지금 φ 는 전부 집계 스칼라(진행률·활성수·스페어수)이고, 설계 §2 가 상태의
# 필수 블록이라고 못 박은 두 가지가 통째로 빠져 있다:
#   X_C = 지금 누가 무엇에 묶여 있고 그 작업이 얼마나 진행됐는가 (전환비용의 원천)
#   X_G = 로봇과 부품이 물리적으로 어디 있는가 (Ryan 질문 (c) 가 정확히 이것을 묻는다)
# 같은 "로봇 1대 고장"이라도 그 로봇이 유휴인지 화물을 절반 옮긴 상태인지에 따라 NOOP 의 값이
# 완전히 달라지는데, 현재 φ 에는 그 차이를 담은 축이 없다. 그러니 φ 가 못 맞히는 게 당연하다.
#
# 원칙은 기존과 같다 — **원자료만 덤프하고 서술자는 파이썬에서 계산**한다. 서술자를 여기서 구우면
# 정의를 바꿀 때마다 몇 시간짜리 라벨링을 버려야 한다.

"활성 스케줄 노드 -> 그 노드에 묶인 로봇 id 목록. monitor.jl 의 _mon_actors 와 같은 규약이지만,
 이 생성기는 monitor 를 로드하지 않으므로 여기 최소판을 둔다."
function _ds_actors(node, env)
    try
        if node isa Union{CB.RobotGo, CB.RobotStart}
            return Any[CB.node_id(CB.entity(node))]
        elseif node isa Union{CB.TransportUnitGo, CB.FormTransportUnit, CB.DepositCargo}
            return collect(keys(CB.robot_team(node)))
        end
    catch; end
    return Any[]
end

"스케줄 노드 -> 커밋먼트 모드. IDLE 은 '어떤 활성 노드에도 안 묶임'을 뜻하므로 여기 없다."
function _ds_mode(node)
    node isa CB.TransportUnitGo && return "CARRY"
    node isa CB.RobotGo && return "TRANSIT"
    node isa Union{CB.FormTransportUnit, CB.DepositCargo, CB.LiftIntoPlace} && return "MANIPULATE"
    return "IDLE"
end

"노드의 목표 위치(x,y). 없으면 (NaN, NaN)."
function _ds_goal_xy(node)
    try
        t = CB.global_transform(CB.goal_config(node)).translation
        return (Float64(t[1]), Float64(t[2]))
    catch
        return (NaN, NaN)
    end
end

"씬트리 노드의 현재 전역 위치(x,y). 없으면 (NaN, NaN)."
function _ds_xy(n)
    try
        t = CB.global_transform(n).translation
        return (Float64(t[1]), Float64(t[2]))
    catch
        return (NaN, NaN)
    end
end

function capture_raw(env)
    rids = Int[]
    try
        for n in CB.get_nodes(env.scene_tree)
            CB.matches_template(CB.RobotNode, n) && push!(rids, _idint(CB.node_id(n)))
        end
    catch; end
    sort!(rids)
    # SoC: fleet 의 키를 정수 id 로 접어서 로봇 목록과 맞춘다(배터리 레이어가 꺼져 있으면 전부 NaN).
    socmap = Dict{Int,Float64}()
    try
        fl = CB.BATTERY_FLEET[]
        fl === nothing || for (k, v) in fl.soc; socmap[_idint(k)] = Float64(v); end
    catch; end
    socs = [get(socmap, i, NaN) for i in rids]
    # 로봇별 잔여 운반작업 — work_energy_mismatch / work_at_risk 의 재료.
    pend = Int[]
    try
        byid = Dict{Int,Any}()
        for n in CB.get_nodes(env.scene_tree)
            CB.matches_template(CB.RobotNode, n) && (byid[_idint(CB.node_id(n))] = CB.node_id(n))
        end
        for i in rids
            push!(pend, Int(try _agent_pending_tasks(env, byid[i]) catch; -1 end))
        end
    catch; pend = fill(-1, length(rids)) end
    stalled = try [_idint(r) for r in CB.stalled_robots()] catch; Int[] end
    spares  = try [_idint(r) for r in CB.active_spares()]  catch; Int[] end
    # 제한구역(원): staging_conflict 를 파이썬에서 재계산하기 위한 기하 원자료.
    zk = String[]; zx = Float64[]; zy = Float64[]; zr = Float64[]
    try
        for (k, z) in CB.RESTRICTION_ZONES[]
            c = Vector{Float64}(CB.get_center(z)[1:2])
            push!(zk, string(k)); push!(zx, c[1]); push!(zy, c[2]); push!(zr, Float64(CB.get_radius(z)))
        end
    catch; end
    # 적치영역(원) + 그 영역이 아직 "미완"인지. 미완인 것만 staging_conflict 의 분모가 된다.
    sk = String[]; sx = Float64[]; sy = Float64[]; sr = Float64[]; sp = Bool[]
    try
        for (aid, ball) in env.staging_circles
            c  = Vector{Float64}(CB.get_center(ball)[1:2])
            ac = try CB._assembly_complete_node(env, aid) catch; nothing end
            v  = ac === nothing ? nothing : (try CB.get_vtx(env.sched, CB.node_id(ac)) catch; nothing end)
            push!(sk, string(aid)); push!(sx, c[1]); push!(sy, c[2])
            push!(sr, Float64(CB.get_radius(ball)))
            push!(sp, !(v === nothing || v in env.cache.closed_set))     # true = 아직 안 끝난 적치영역
        end
    catch; end
    # ---- X_C: 로봇별 커밋먼트(무슨 작업에 묶였고 목표가 어디인가) ------------------------
    # 활성 노드를 한 번 훑어 rid => (모드, 목표x, 목표y) 로 역매핑한다. 어떤 활성 노드에도
    # 안 잡힌 로봇은 IDLE 이고 목표가 없다(NaN). 이 세 값이 "지금 진행 중인 일을 버리면
    # 얼마를 버리는가" = 전환비용을 파이썬에서 재계산할 수 있게 하는 원자료다.
    commit = Dict{Int,Tuple{String,Float64,Float64}}()
    n_act_carry = 0; n_act_transit = 0; n_act_manip = 0
    try
        for v in env.cache.active_set
            node = CB.get_node(env.sched, v).node
            m = _ds_mode(node)
            m == "CARRY" && (n_act_carry += 1)
            m == "TRANSIT" && (n_act_transit += 1)
            m == "MANIPULATE" && (n_act_manip += 1)
            m == "IDLE" && continue
            gx, gy = _ds_goal_xy(node)
            for r in _ds_actors(node, env)
                commit[_idint(r)] = (m, gx, gy)
            end
        end
    catch; end

    # ---- X_G: 로봇 위치 + 부품/조립체 위치 ------------------------------------------------
    rx = Float64[]; ry = Float64[]; rmode = String[]; rgx = Float64[]; rgy = Float64[]
    try
        byid = Dict{Int,Any}()
        for n in CB.get_nodes(env.scene_tree)
            CB.matches_template(CB.RobotNode, n) && (byid[_idint(CB.node_id(n))] = n)
        end
        for i in rids
            n = get(byid, i, nothing)
            x, y = n === nothing ? (NaN, NaN) : _ds_xy(n)
            m, gx, gy = get(commit, i, ("IDLE", NaN, NaN))
            push!(rx, x); push!(ry, y); push!(rmode, m); push!(rgx, gx); push!(rgy, gy)
        end
    catch
        rx = fill(NaN, length(rids)); ry = fill(NaN, length(rids))
        rmode = fill("?", length(rids)); rgx = copy(rx); rgy = copy(ry)
    end

    # ---- X_H: 위험 프로세스의 로봇별 물리 서술자 (2026-08-02 추가) ------------------------
    # 왜 필요한가 — 설계 §2.6 은 "비용을 경과시간으로 매기면 process 가 time-homogeneous 하고
    # t 는 상태에서 빠진다"고 했다. 그 근거는 **시간에 따라 쌓이는 양이 상태 안에 있다**는 전제다.
    # 그런데 고장률이
    #     λ_r = (1/mtbf)·mode·f(r)·exp(β_u·û_r + β_s·(1−soc_r)),   û_r = usage_s / usage_scale
    # 이고 `usage_s`(누적 활동 초)는 단조증가 축적량인데, 이게 φ 에 없었다. 즉 같은 φ 를 가진 두
    # 상태가 서로 다른 고장률을 가질 수 있었고, 그건 설계 §3.1 이 경고한 **열화 기억(degradation
    # memory)** 위협이 그대로 살아 있다는 뜻이다(T2 가 반증하려던 바로 그것).
    # λ 와 p_fail_60s 까지 함께 담는다 — 이건 kind one-hot 없이도 "지금 얼마나 위험한가"를
    # 말해주는 값이라 §8.1 의 kind-비의존 요구와도 맞고, 처음 보는 사건도 φ 안에 떨어진다.
    # 위험 프로세스가 꺼져 있으면 hazard_features 가 빈 Dict 를 주므로 전부 NaN → 파이썬에서
    # 해당 서술자가 아예 생성되지 않는다(0.0 으로 채워 거짓 신호를 만들지 않는다).
    rusage = Float64[]; ruhat = Float64[]; rlam = Float64[]; rpf60 = Float64[]
    try
        hf = Dict{Int,Any}()
        for (k, v) in CB.hazard_features(env); hf[_idint(k)] = v; end
        for i in rids
            f = get(hf, i, nothing)
            push!(rusage, f === nothing ? NaN : Float64(f.usage_s))
            push!(ruhat,  f === nothing ? NaN : Float64(f.u_hat))
            push!(rlam,   f === nothing ? NaN : Float64(f.lambda))
            push!(rpf60,  f === nothing ? NaN : Float64(f.p_fail_60s))
        end
    catch
        rusage = fill(NaN, length(rids)); ruhat = copy(rusage)
        rlam = copy(rusage); rpf60 = copy(rusage)
    end

    # 부품(ObjectNode)/하위조립(AssemblyNode)이 **물리적으로 지금 어디에 있는가**.
    # closed_set 로 "이미 제자리에 놓였는가"를 함께 남긴다 — 남은 운반 일감의 기하가 곧
    # 후속 assignment 문제의 입력이다(Ryan 질문 (c)).
    ck = String[]; cx = Float64[]; cy = Float64[]; cdone = Bool[]
    try
        placed = Set{Any}()
        for v in env.cache.closed_set
            node = CB.get_node(env.sched, v).node
            node isa CB.LiftIntoPlace && (try push!(placed, CB.node_id(CB.entity(node))) catch; end)
        end
        for n in CB.get_nodes(env.scene_tree)
            (CB.matches_template(CB.ObjectNode, n) || CB.matches_template(CB.AssemblyNode, n)) || continue
            nid = CB.node_id(n); x, y = _ds_xy(n)
            push!(ck, string(nid)); push!(cx, x); push!(cy, y); push!(cdone, nid in placed)
        end
    catch; end

    return (raw_robot_id = rids, raw_robot_soc = socs, raw_robot_pending = pend,
            raw_robot_x = rx, raw_robot_y = ry, raw_robot_mode = rmode,
            raw_robot_goal_x = rgx, raw_robot_goal_y = rgy,
            raw_robot_usage = rusage, raw_robot_uhat = ruhat,
            raw_robot_lambda = rlam, raw_robot_pfail60 = rpf60,
            raw_n_carry = n_act_carry, raw_n_transit = n_act_transit, raw_n_manip = n_act_manip,
            raw_cargo_id = ck, raw_cargo_x = cx, raw_cargo_y = cy, raw_cargo_placed = cdone,
            raw_stalled_id = stalled, raw_spare_id = spares,
            raw_n_closed = length(env.cache.closed_set),
            raw_n_active = length(env.cache.active_set),
            raw_n_total  = length(CB.get_nodes(env.sched)),
            raw_zone_key = zk, raw_zone_x = zx, raw_zone_y = zy, raw_zone_r = zr,
            raw_stage_id = sk, raw_stage_x = sx, raw_stage_y = sy, raw_stage_r = sr,
            raw_stage_pending = sp)
end

# capture_features : OOD 사건이 터진 그 순간의 상태를 named tuple(이름표 달린 값 묶음)로 뽑아낸다.
#   이게 나중에 surrogate 의 입력 특징(feature)이 됨. ctx=이벤트 문맥, kind=OOD종류, severity=심각도, n_spare_cfg=설정된 예비수.
#   2026-07-31: 기존 필드는 하나도 건드리지 않고 raw_* 원자료를 덧붙인다(기존 분석 전부 그대로 동작).
function capture_features(env, ctx, kind, severity, n_spare_cfg)
    closed = length(env.cache.closed_set)               # 지금까지 닫힌(완료된) 노드 수
    total  = length(CB.get_nodes(env.sched))            # 전체 노드 수
    nl_obs = last_event_nl()                            # 이 사건의 자연어 관찰(주입 시점에 기록된 것)
    zrad = NaN; zovl = -1.0; zroot = -1.0               # zone 관련 특징 기본값(zone OOD가 아니면 그대로)
    if ctx.type === :zone
        zrad = try Float64(CB.get_radius(CB.RESTRICTION_ZONES[][ctx.zone])) catch; NaN end   # zone 반지름
        zovl = try zone_overlap_frac(env, ctx.zone) catch; -1.0 end                          # zone 겹침 비율
        # core zone 의 harm 은 staging 겹침(zovl)에는 거의 안 나타난다 — 중앙 코어를 덮으면 겹치는
        # staging 원이 없을 수도 있다. **못 옮기는 root 목표를 몇 % 삼켰나**가 그 harm 이므로 따로 싣는다.
        # 이 열이 없으면 :zoneblk 와 :zonecore 가 상태로 구별되지 않아(라벨은 일부러 같다) 학습 불가가 된다.
        zroot = try zone_root_cover_frac(env, ctx.zone) catch; -1.0 end
    end
    # ---- STEP 3: 구역 사건의 기하 원시값(primitive) ---------------------------------------
    # zone_overlap 스칼라 하나로는 "무엇이 왜 막혔는가"를 표현할 수 없다. 진단기가 이미 계산해 둔
    # 술어들을 그대로 싣는다 — 정책이 **판정을 읽는 게 아니라 스스로 판정하도록** 하려면 이 값들이
    # 관측 어휘에 있어야 한다.
    #
    # !!! `verdict`(최소수복 판정)은 **일부러 싣지 않는다**. 그건 정답이라 오라클/게이트의 것이고,
    #     행에 실으면 정책이 추론이 아니라 답을 베끼게 된다(zone_diagnosis.jl 의 note 참조).
    zd = _zd(ctx)     # shim 이 붙여둔 진단(스칼라만). zone 이 아니거나 DS_ZONE_DIAG=0 이면 nothing.
    zblk  = zd === nothing ? -1  : Int(zd.n_blocked)              # 구역이 덮은 미개시 조립체 수
    zfea  = zd === nothing ? -1  : Int(zd.n_restage_feasible)     # 그중 실제로 옮길 자리가 있는 수
    zwork = zd === nothing ? -1  : Int(zd.n_work_overlap)         # 겹친 미완 작업 디스크 수
    ztf   = zd === nothing ? -1  : Int(zd.n_teams_forming)        # 지금 형성 중인 운반팀 수
    ztc   = zd === nothing ? -1  : Int(zd.n_teams_covered)        # 그중 구역에 갇힌 팀 수
    zrel  = zd === nothing ? -1  : (zd.relocate_feasible ? 1 : 0) # 벗어날 강체이동이 존재하는가
    zdlt  = zd === nothing ? -1.0 : (isfinite(zd.relocate_norm) ? Float64(zd.relocate_norm) : -1.0)  # 그 최소 이동거리
    return (                                            # (a = b, ...) = named tuple
        zone_overlap  = zovl,      # 0 = blocks no pending staging area (harmless); ~0.8 = swallows one
        zone_root_cover = zroot,   # fraction of the ROOT's un-relocatable delivery goals swallowed (harm axis)
        kind          = row_kind(kind),      # the kind the CONTROLLER sees (harmless variants share it)
        severity      = Float64(severity),
        n_spare_cfg   = Int(n_spare_cfg),
        spare_count   = (try length(CB.active_spares()) catch; 0 end),   # 지금 쓸 수 있는 예비 로봇 수(정답을 바꾸는 핵심 특징)
        closed_at_fire= closed,
        total_nodes   = total,
        progress      = total > 0 ? closed/total : 0.0,   # 진행률(닫힌/전체)
        n_active      = length(env.cache.active_set),
        agent_pending = _agent_pending_tasks(env, ctx.agent),   # 대상 로봇의 남은 작업 수(무해/유해 구분 핵심)
        # 사건 대상 로봇의 정수 id. raw_robot_* 평행벡터를 인덱싱하는 **조인 키**다.
        # 이게 없으면 "고장난 그 로봇이 지금 뭘 하고 있었나"를 파이썬에서 되찾을 수 없다.
        target_id     = (ctx.agent === nothing ? -1 : _idint(ctx.agent)),
        soc           = ctx.type === :battery ? Float64(ctx.soc) : NaN,   # battery OOD면 남은 충전량(State of Charge)
        zone_radius   = zrad,
        # STEP 3 기하 원시값. zone 사건이 아니면 전부 -1 (기존 zone_overlap 의 sentinel 관례와 동일).
        zone_blocked        = zblk,
        zone_restage_feasible = zfea,
        zone_work_overlap   = zwork,
        zone_teams_forming  = ztf,
        zone_teams_covered  = ztc,
        zone_relocatable    = zrel,
        zone_relocate_norm  = zdlt,
        valid_mask    = valid_actions(ctx),   # 이 상황에서 애초에 가능한(유효한) 매크로들의 마스크
        # NL observation channel: what a language-model producer is actually given. Empty string only
        # if the injector recorded no truth pair (then the Python side falls back to a clearly-flagged
        # reconstruction -- see nl_events.py). Never contains the ground-truth label.
        nl            = nl_obs,
        nl_source     = isempty(nl_obs) ? "missing" : "captured",   # 이 문장이 진짜 캡처인지 표시(출처 추적)
    ) |> f -> merge(f, capture_raw(env))   # 원자료를 덧붙임(파생 서술자는 파이썬에서 계산)
end

# =========================================================================================
#  NOMINAL ARM  (kind = "none") -- 두 번째 결정함수의 재료
# =========================================================================================
# 왜 필요한가 (md/README.md §5 "3분류"; 원문 DESIGN_CLASSIFIER.md §2 는 2026-08-02 에 통합됨 —
#   git show HEAD:wm4spacecraft_manufacturing/md/DESIGN_CLASSIFIER.md):
#   논문의 3분류는 결정함수가 **두 개**여야 나온다. 하나는 "아는 교란처럼 보이는가", 다른 하나는
#   "교란 없는 빌드처럼 보이는가". 두 번째를 학습하려면 교란이 없는 런의 상태가 필요한데,
#   지금 데이터셋에는 그런 행이 0개다. 그래서 그건 빠진 baseline 이 아니라 **빠진 결정함수**다.
#
# 왜 거의 공짜인가:
#   control 판(inject=false)은 admissibility 를 위해 **이미 매 instance 마다 돌고 있다**. 지금은
#   결과 3개(ctrl_complete/closed/makespan)만 남기고 나머지를 버린다. 여기서 하는 일은 그 판에
#   "관찰 지점"을 하나 심어 상태를 기록하는 것뿐 -- 새 시뮬레이션을 추가하지 않는다.
#
# 왜 FEAT[] 을 재사용하지 않는가:
#   run_one 은 `fired = FEAT[] !== nothing` 으로 "OOD 가 터졌나"를 판정한다. nominal 캡처를 같은
#   상자에 넣으면 교란 없는 판이 fired=true 로 보고되고, load_df(fired==True) 를 쓰는 모든 기존
#   분석이 조용히 오염된다. 그래서 상자를 따로 둔다.
const NOMINAL_FEAT = Ref{Any}(nothing)

"nominal arm 을 켤지. DS_NOMINAL=1 이면 control 판에서 상태를 캡처해 kind=\"none\" 행을 쓴다."
const NOMINAL_ARM = get(ENV, "DS_NOMINAL", "0") == "1"

"""
DS_NOMINAL_ONLY=1 : control 판만 돌고 매크로 5판은 건너뛴다.

왜 이 모드가 있나 -- 기존 데이터셋(openworld_merged.jsonl)에는 매크로 5판이 **이미 다 있고**
빠진 것은 nominal 행뿐이다. 전체를 다시 돌리면 이미 가진 라벨을 6분의 6 비용으로 다시 만드는
셈이다. 이 모드는 빠진 1/6(control 판)만 만들어 기존 파일에 합칠 수 있게 한다.

전제: control 판은 (kind, severity, seed, n_spare) 가 같으면 재현된다 -- 같은 시드, "OOD 만 뺀
같은 세계"이므로. 그래서 나중에 instance id 로 기존 행과 안전하게 조인된다.
"""
const NOMINAL_ONLY = get(ENV, "DS_NOMINAL_ONLY", "0") == "1"

"""
DS_INSTANCES_FROM=<dump.jsonl> : instance 목록을 **기존 덤프에서 그대로 읽어온다**.

왜 필요한가 -- openworld_merged.jsonl 은 여러 번의 실행을 합친 파일이라, DS_SPARES/DS_BSOC 같은
환경변수로 그 목록을 되살리려면 추측이 섞인다(실제로 faultidle 은 sp3 만 있는데 SPARES=1,3 으로
돌리면 sp1 이 더 생긴다). 목록이 조금이라도 어긋나면 새로 만든 nominal 행이 기존 행과 짝이 안
맞아 조인이 깨진다. 그래서 추측하지 않고 원본에서 (variant, severity, seed, n_spare_cfg) 를
그대로 읽는다.

JSON 파서를 쓰지 않는 이유: 이 스크립트는 쓰기도 손수 만든 jrow 로 한다(외부 의존 없음). 읽는
쪽도 필요한 4개 필드만 정규식으로 뽑아 같은 원칙을 지킨다.
"""
const INSTANCES_FROM = get(ENV, "DS_INSTANCES_FROM", "")

"덤프 한 줄에서 \"key\":value 를 뽑는다. 문자열이면 따옴표를 벗긴다."
function _jfield(line::AbstractString, key::AbstractString)
    m = match(Regex("\"" * key * "\":(\"[^\"]*\"|[^,}]+)"), line)
    m === nothing && return nothing
    v = m.captures[1]
    return startswith(v, "\"") ? v[2:end-1] : v
end

"기존 덤프 -> 고유한 (kind, severity, seed, n_spare, fire_at) 목록. 순서는 파일 등장 순서를 따른다."
function instances_from_dump(path::AbstractString)
    seen = Set{Tuple{Symbol,Float64,Int,Int,Int}}()
    out = Tuple{Symbol,Float64,Int,Int,Int}[]
    for line in eachline(path)
        isempty(strip(line)) && continue
        # variant = 생성용 세부 종류(:faultidle 등). kind 가 아니라 variant 를 써야 원본 판을 재현한다.
        v = _jfield(line, "variant"); v === nothing && continue
        v == "none" && continue                       # 이미 있는 nominal 행은 건너뛴다(중복 방지)
        sev = _jfield(line, "severity"); sd = _jfield(line, "seed"); sp = _jfield(line, "n_spare_cfg")
        (sev === nothing || sd === nothing || sp === nothing) && continue
        # fire_target 은 2026-08-04 이후 덤프에만 있다. 없으면 0 = 예전 사다리 = 원본 재현.
        ft = _jfield(line, "fire_target")
        t = (Symbol(v), parse(Float64, sev), parse(Int, sd), parse(Int, sp),
             ft === nothing ? 0 : parse(Int, ft))
        t in seen && continue
        push!(seen, t); push!(out, t)
    end
    return out
end

"""
관찰 지점(닫힌 노드 수의 목표값). OOD 발화점들(FIRE_POINTS: 8~60)의 한복판이라 교란 런과
진행도가 비교 가능하다.

주의: 이건 **목표값이지 정확한 발화점이 아니다**. schedule_ood_at_closed! 는 시뮬 배치가 끝날 때
닫힌 수를 확인하므로, 실제 캡처는 이 값 이상인 첫 확인 지점에서 일어난다(실측: 목표 20 -> 실제 58).
그래도 비교가능성은 유지된다 -- control 판은 "OOD 만 뺀 같은 세계"라 같은 배치 경계에서 멈추고,
실제로 nominal 과 fault 가 **둘 다 closed=58 / progress=0.185** 에서 잡혔다.
"""
const NOMINAL_AT = parse(Int, get(ENV, "DS_NOMINAL_AT", "20"))

# 교란이 없으므로 이벤트 문맥도 없다. capture 가 읽는 5개 필드만 갖춘 합성 문맥을 준다.
const NOMINAL_CTX = (type = :none, agent = nothing, zone = nothing, assembly = nothing, soc = NaN)

# capture_features 를 부르지 않고 따로 쓰는 이유: 그쪽은 valid_actions(ctx) 등 OOD 전용 경로를 타므로
# :none 문맥에서 무슨 일이 벌어질지 보장할 수 없다. OOD 경로는 건드리지 않는 게 이 변경의 원칙이다.
function capture_nominal_features(env, n_spare_cfg)
    closed = length(env.cache.closed_set)
    total  = length(CB.get_nodes(env.sched))
    return (
        zone_overlap  = -1.0,          # 구역 없음 (파이썬 쪽 is_spatial 판정이 -1 을 '해당없음'으로 읽는다)
        zone_root_cover = -1.0,        # 구역 없음 → root 목표 삼킴 비율도 '해당없음'
        kind          = "none",
        severity      = 0.0,           # 교란이 없으니 심각도 0
        n_spare_cfg   = Int(n_spare_cfg),
        spare_count   = (try length(CB.active_spares()) catch; 0 end),
        closed_at_fire= closed,
        total_nodes   = total,
        progress      = total > 0 ? closed/total : 0.0,
        n_active      = length(env.cache.active_set),
        agent_pending = -1,            # 피해 로봇 없음 (-1 = 해당없음, _agent_pending_tasks 와 같은 규약)
        soc           = NaN,           # 배터리 사건 아님
        zone_radius   = NaN,
        valid_mask    = Int[0],        # nominal 판에는 고를 대응이 없다 -- NOOP 뿐
        nl            = "The build is proceeding normally; no disturbance has occurred.",
        nl_source     = "nominal",
    )
end

"control 판에 '관찰만 하는' 훅을 예약한다. 액션이 nothing 을 돌려주므로 이벤트로 기록되지 않는다."
function schedule_nominal_probe!(n_spare; at::Int = 0)
    act = e -> begin
        NOMINAL_FEAT[] === nothing || return nothing      # 한 번만
        NOMINAL_FEAT[] = capture_nominal_features(e, n_spare)
        return nothing                                    # nothing = 교란 없음, NL 없음, 이벤트 아님
    end
    # 발화 시점이 instance 차원이 된 뒤(DS_FIRE_GRID)에는 control 판의 관찰 지점도 **같은 진행도**로
    # 따라가야 한다. 안 그러면 nominal 행은 전부 closed=58 에 몰리고, 교란 런과 진행도가 어긋나
    # "OOD 만 뺀 같은 세계"라는 대조 조건이 깨진다. at=0 이면 예전 상수 그대로.
    try CB.schedule_ood_at_closed!(at > 0 ? at : NOMINAL_AT, act) catch e
        @warn "nominal probe could not be scheduled" exception = e
    end
    return nothing
end

# _event_type : 생성용 kind 가 실제로 어떤 이벤트 타입으로 분류되는지(:zoneblk 는 :zone 이벤트로 뜸).
_event_type(kind::Symbol) = kind in (:zoneblk, :zoneharm, :zonecore) ? :zone :
                            kind === :faultidle ? :fault : kind

# ---- producer: capture at the studied event, then play macro `a`; canonical elsewhere ---
# studied_prod : "respec seam(개입 지점)"에 꽂을 정책 함수를 만든다. 매크로 번호 a 를 대상 이벤트에 적용.
#   반환값은 (env, ev)->... 익명함수. 이 함수가 매 OOD 이벤트마다 호출됨.
const STUDIED_AGENT = Ref{Any}(nothing)   # 연구 대상 사건의 피해 로봇(캐스케이드 판정에 씀)

studied_prod(a::Int, kind::Symbol, severity, n_spare_cfg; hz_seed = nothing) = (env, ev) -> begin
    ctx = event_context(env, ev); NEV[] += 1            # 이벤트 문맥 추출 + 이벤트 카운트 증가
    if ctx.type === _event_type(kind) && FEAT[] === nothing        # THE studied event (first of its type)
        FEAT[] = capture_features(env, ctx, kind, severity, n_spare_cfg)   # 이 순간 특징을 딱 한 번 저장
        STUDIED_AGENT[] = ctx.agent
        # ---- 위험 시계 arm: 정확히 이 순간 ------------------------------------------------
        # 여기보다 앞에서 켜면 결정 이전 궤적까지 rollout 마다 달라져 상태 s 가 고정되지 않는다.
        # 여기서 켜야 "s⁺ = f(s,ω) 다음 미래를 표집" 이라는 Q(s,ω) 의 정의와 정확히 일치한다.
        hz_seed === nothing || CB.enable_hazard!(env; params = HZ_PARAMS, seed = hz_seed)
        a == 0 && return nothing                        # a==0(NOOP)이면 아무 개입도 안 함
        return action_to_proposal(ctx, a)               # 그 외엔 매크로 a 를 실제 DSL 제안으로 변환해 적용
    end
    # ---- 위험 프로세스가 만든 **독립적인** 후속 고장 -> 배경(canonical) 정책으로 대응 ----------
    # 아래 CASCADE RULE 은 "후속 알람은 전부 NOOP" 이지만, 그건 후속 알람이 연구 대상 사건의
    # 직접적 결과일 때의 이야기다(방전된 그 로봇이 멈춰서 내는 2차 알람 등). MC 모드에서 위험
    # 프로세스가 만드는 고장은 **다른 로봇의 독립 사건**이고, 그걸 전부 NOOP 으로 두면 우리가 재는
    # 것이 Q(s,ω) 가 아니라 "한 번 결정하고 그 뒤로는 무슨 일이 나도 방치하는 정책의 가치" 가 된다.
    # 그래서 대상 로봇이 다르면 배경 정책(canonical)으로 대응하고, 같으면 기존 캐스케이드 규칙을 지킨다.
    if hz_seed !== nothing && ctx.agent !== nothing && STUDIED_AGENT[] !== nothing &&
       ctx.agent != STUDIED_AGENT[]
        return action_to_proposal(ctx, canonical_action(ctx))
    end
    # CASCADE RULE. Any further OOD alarm is a CONSEQUENCE of the studied event — e.g. a deep battery
    # discharge stalls the robot, and the stall raises its own breakdown alarm (battery.jl `_fire_stall_ood!`).
    # Letting the fixed background policy answer that alarm canonically (= Replace) silently RE-DOES the
    # studied decision inside the NOOP arm: every macro then produces a byte-identical sim (observed:
    # NOOP and Replace both closed=172). The studied decision must own its own consequences, so
    # downstream alarms get NOOP. Only :reform (the background navigation/team-wedge recovery, which is
    # not an OOD response) stays canonical — that is the "hold the background policy fixed" rule.
    ctx.type === :reform && return action_to_proposal(ctx, canonical_action(ctx))   # 배경 재정렬(:reform)만 평소대로 처리
    return nothing                                      # 그 밖의 후속 알람은 NOOP(연구 대상 결정이 자기 결과를 책임지게)
end
# canonical_bg : 개입 없는 "정상 배경 정책". control 런(OOD 안 터뜨림)에 쓰이며 모든 이벤트를 표준 방식으로 처리.
canonical_bg(env, ev) = (NEV[] += 1; action_to_proposal(event_context(env, ev), canonical_action(event_context(env, ev))))

# =========================================================================================
#  EPISODE MODE (deterministic MDP)  --  DS_EPISODE_N > 0.  기본 0 = 완전히 비활성(기존 경로 불변).
# =========================================================================================
# WHY. An instance here has exactly ONE event, so the only thing a label can express is the
# immediate consequence of one decision. The coupling that makes this a sequential problem --
# spending a spare NOW leaves none for the NEXT breakdown, restaging an assembly NOW changes where
# the next zone bites -- can never appear. That is why what we train is Q^π(s,a) for a single
# decision, i.e. a contextual bandit, not an MDP.
#
# DETERMINISM. The simulator consumes `rng` in exactly one place (initial robot placement,
# full_demo.jl), so (seed, policy) fixes the whole trajectory. Consequences:
#   · ONE one-step-deviation rollout is the EXACT Q^π(s_t,a) -- no sample average needed.
#   · No expectation, no variance, no common-random-numbers machinery. What we get is a
#     DETERMINISTIC MDP, which is enough for the credit-assignment question and is all this
#     simulator can honestly support.
#
# SCHEDULED EVENT vs CASCADE ALARM. A deep discharge stalls a robot, and the stall raises its own
# breakdown alarm. That alarm is a CONSEQUENCE of the decision just made, not a new decision, so it
# keeps the existing CASCADE RULE (answer it with NOOP; only :reform stays canonical). It cannot be
# told apart by event type -- both arrive as :fault -- so each SCHEDULED action registers the NL it
# emitted in EP_SCHED_NL, and the producer treats only those as decision points.
const EPISODE_N = parse(Int, get(ENV, "DS_EPISODE_N", "0"))     # 에피소드당 스케줄할 사건 수(0=모드 끔)
const EP_KINDS  = [Symbol(s) for s in split(get(ENV, "DS_EP_KINDS", "fault,battery,zoneblk"), ",")]
const EP_LO     = parse(Int, get(ENV, "DS_EP_LO", "8"))         # 사건이 터질 closed-노드 구간 [lo,hi]
const EP_HI     = parse(Int, get(ENV, "DS_EP_HI", "60"))
const EP_SEV    = Dict(:fault   => 1.0,
                       :battery => parse(Float64, get(ENV, "DS_EP_BSOC",  "0.12")),
                       :zoneblk => parse(Float64, get(ENV, "DS_EP_ZFRAC", "0.9")),
                       # :zonecore 의 severity 는 **root 하역 목표를 삼키는 비율**이다(offset 이 아니다).
                       # 1.0 = 최종 조립 목표 전부를 덮음 = NOOP 으로는 완주 불가.
                       :zonecore => parse(Float64, get(ENV, "DS_EP_CFRAC", "0.6")))
# 개입 비용. export_surrogate.py 의 MACRO_COST 와 반드시 같아야 한다(보상 정의가 두 곳에 있으므로).
const MACRO_COST = Dict(0 => 0.0, 1 => 1.0, 2 => 0.3, 3 => 1.0, 4 => 1.0,
    # 조합 팔의 비용 = 구성 primitive 비용의 합. features_agnostic.psi 의 a_cost 와 같은 값이어야 한다
    # (ForbidAgent 0.8 + ReformTeam 1.0 = 1.8 / Deprioritize 0.3 + ForbidWindow 0.5 = 0.8).
    5 => 1.8, 6 => 0.8,
    # RelocateBuild = 빌드 전체를 옮기는 전역 개입. ForbidZone(조립체 하나 이동, 1.0)보다 영향 범위가
    # 넓으므로 더 비싸게 매긴다. features_agnostic.MACRO_COST[7] / _PRIMITIVE_TABLE["RelocateBuild"] 와
    # **같은 값**이어야 한다(보상 정의가 여러 곳에 있으므로 — README 함정 29).
    7 => 1.5,
    # SwapBattery = 배터리는 무제한(재고 관리 안 함)이고 현장 작업이라 개입 중 가장 싸다.
    # Replace(1.0)보다 확실히 싸야 "싸게 살릴까 비싸게 살릴까"가 진짜 선택이 된다.
    # features_agnostic.MACRO_COST[8] 과 **같은 값**이어야 한다(보상 정의가 여러 곳에 있음).
    8 => 0.2)

# FIXED-STEP PROBES -- 두 문제정의 중 하나를 오늘 고르지 않기 위한 장치.
#
# Event-driven (SMDP) and fixed-step MDP disagree on ONE thing that matters: under the event-driven
# formulation the policy can only ever REACT, because a decision epoch exists only where a
# disturbance already happened. A fixed-step formulation lets it act BEFORE one -- e.g. shift work
# off a draining robot pre-emptively -- which is the whole point of energy-aware fleet control.
#
# Rather than commit tonight, probe the state every DS_PROBE_EVERY closed nodes. The probe INJECTS
# NOTHING (returns nothing, so no NL is enqueued and no respec event is raised); it only records
# raw state. One simulation then yields BOTH datasets: event-time captures for the SMDP transitions,
# probe captures for the fixed-step ones. Costs no extra runs. Which formulation is right becomes a
# measurement in the morning (how much does the state actually move between probes?) instead of a
# guess tonight.
# [한국어] 사건 기반은 "반응"만 가능하고 고정 스텝은 "선제 행동"이 가능하다 -- 에너지 관리에는 후자가
#   필요할 수 있다. 오늘 고르지 않기 위해, 닫힌 노드 K개마다 상태만 찍는 probe 를 심는다(주입 없음).
#   같은 시뮬 한 판에서 두 형태의 전이가 모두 나오고 추가 비용은 0이다.
const PROBE_EVERY = parse(Int, get(ENV, "DS_PROBE_EVERY", "10"))   # 0 이면 probe 끔
const PROBE_TRACE = Ref(Any[])

const EP_SCHED_NL   = Ref(String[])      # 이번 판에서 "스케줄된" 사건이 실제로 낸 NL 문장들(발화 순서)
const EP_SCHED_META = Ref(Any[])         # 그 사건들의 (kind, severity) -- 위 배열과 같은 순서
const TRACE         = Ref(Any[])         # 결정 궤적: 결정마다 (decision_idx, macro_taken, feats)
const EP_K          = Ref(0)             # 이번 판에서 지금까지 처리한 스케줄 사건 수

"[lo,hi] 에 n 개 발화점을 균등 배치 + 반슬롯 지터. ood_stream._random_progress_points 와 같은 규칙."
function _ep_points(n::Int, lo::Int, hi::Int, rng)
    n <= 0 && return Int[]
    hi <= lo && return fill(max(lo, 1), n)
    span = hi - lo
    pts = Int[]
    for i in 1:n
        base = lo + round(Int, span * (i - 0.5) / n)
        jit  = round(Int, (2 * rand(rng) - 1) * span / (2n))
        push!(pts, clamp(base + jit, lo, hi))
    end
    return sort(pts)
end

"에피소드 계획 = [(closed 발화점, kind, severity)]. seed 만으로 완전히 결정된다(재현성)."
function episode_plan(seed::Int)
    rng = Random.MersenneTwister(10_000 + seed)          # 인스턴스 seed 와 겹치지 않게 오프셋
    pts = _ep_points(EPISODE_N, EP_LO, EP_HI, rng)
    return [(c, k, get(EP_SEV, k, 1.0)) for (c, k) in zip(pts, [rand(rng, EP_KINDS) for _ in pts])]
end

# 사건 하나짜리 액션. build_injection 의 per-kind 로직을 그대로 옮겨 적되 별도 함수로 둔다 --
# build_injection 을 리팩터링하면 기존 데이터셋의 재현성이 위험해지므로, 중복을 감수하고 분리한다.
function _one_shot_action(kind::Symbol, severity::Float64, idx::Int)
    fired = Ref(false)
    inner = if kind === :fault
        e -> begin
            tgt = single_solo_fault_target(e)
            tgt === nothing && (tgt = try CB.pick_solo_fault_target(e) catch; nothing end)
            tgt === nothing && (tgt = try CB.pick_solo_frontier_target(e) catch; nothing end)
            tgt === nothing ? nothing : CB.fault_action(; target = tgt, obstacle = false, clear = false)(e)
        end
    elseif kind === :battery
        # 에피소드 모드도 같은 규약(severity = 떨어진 뒤의 잔량). DS_BSOC_MODE=drop 이면 옛 뺄셈.
        bf = get(ENV, "DS_BSOC_MODE", "abs") == "abs" ?
             CB.battery_action(soc_target = Float64(severity)) :
             CB.battery_action(soc_drop = clamp(1.0 - severity, 0.1, 1.0))
        e -> bf(e)
    elseif kind === :zoneblk
        zkey = Symbol("zoneblk_ep", idx)                 # 에피소드 안에 zone 이 여러 번 오면 키가 겹치면 안 됨
        e -> place_blocking_zone!(e; key = zkey, offset = severity)
    elseif kind === :zonecore
        zkey = Symbol("zonecore_ep", idx)
        e -> place_core_zone!(e; key = zkey, frac = severity)   # severity = root 목표 삼킴 비율
    else
        error("episode mode: unsupported kind $(kind)")
    end
    return e -> begin
        fired[] && return nothing                        # 한 번만
        nl = inner(e)
        (nl === nothing || isempty(nl)) && return nothing
        fired[] = true
        push!(EP_SCHED_NL[], String(nl))                 # 이 NL 은 "스케줄된 결정"임을 등록
        push!(EP_SCHED_META[], (kind, severity))         # 파생 알람과 구분하는 유일한 근거
        return nl
    end
end

# =========================================================================================
#  배터리 사건의 물리 무장(arming) — 회계 + 정지(stall) + **감속(derate)**
# -----------------------------------------------------------------------------------------
#  [2026-08-05 심각도 구간 재설계]
#  예전 사다리(0.05 / 0.12)는 두 값 모두 정지 임계(DS_STALL=0.15) **아래**라 거동이 똑같았다
#  (둘 다 즉시 정지). 심각도 축이 사실상 점 하나였던 것이다. 새 사다리는 정지 경계를 **걸치도록**
#  잡는다(DS_BSOC 기본 = 0.02 / 0.3 / 0.5):
#      0.02  < thr(0.15)            -> 즉시 정지          (개입 필요)
#      0.3   in (thr, hi=0.5)       -> 감속·계속 일함      (개입은 선택; 비용 대비 이득 문제)
#      0.5   >= hi                  -> 사실상 무영향       (개입은 낭비 = NOOP)
#  가운데 칸이 의미를 가지려면 엔진에 **감속 구간**이 있어야 한다(navigator/battery.jl
#  `set_battery_derate!`). 없으면 0.3 과 0.5 가 둘 다 속도배율 1.0 이라 다시 한 점으로 겹친다.
#  DS_DERATE=0 으로 끄면 예전(계단 함수) 거동으로 돌아간다.
function _arm_battery!(env)
    try
        CB.enable_battery!(env; params = CB.demo_battery_params(
            shrink = parse(Float64, get(ENV, "DS_SHRINK", "200.0"))))          # 용량 축소(짧은 빌드에서 소모가 보이게)
        CB.set_battery_stall!(enabled = true,
            threshold = parse(Float64, get(ENV, "DS_STALL", "0.15")), clear = true, obstacle = false)
        CB.set_battery_derate!(enabled  = get(ENV, "DS_DERATE", "1") == "1",   # 감속 구간(기본 ON)
                               hi       = parse(Float64, get(ENV, "DS_DERATE_HI",  "0.5")),
                               min_factor = parse(Float64, get(ENV, "DS_DERATE_MIN", "0.35")))
    catch e; @warn "enable_battery/stall/derate failed" exception = e end
    return nothing
end

"계획대로 M 개 트리거를 예약. 배터리가 하나라도 있으면 pre_sim 훅(배터리 회계+stall)을 함께 돌려준다."
function build_episode_injection(plan)
    sched_fn = () -> begin
        for (i, (c, kind, sev)) in enumerate(plan)
            CB.schedule_ood_at_closed!(c, _one_shot_action(kind, sev, i))
        end
        # 고정 스텝 probe: 아무것도 주입하지 않고(nothing 반환) 상태만 기록한다.
        if PROBE_EVERY > 0
            for c in PROBE_EVERY:PROBE_EVERY:parse(Int, get(ENV, "DS_PROBE_MAX", "400"))
                CB.schedule_ood_at_closed!(c, e -> begin
                    try push!(PROBE_TRACE[], (closed_at = length(e.cache.closed_set),
                                              raw = capture_raw(e))) catch end
                    return nothing                    # 주입 없음 = respec 이벤트가 생기지 않음
                end)
            end
        end
    end
    hook = any(p -> p[2] === :battery, plan) ? (env -> _arm_battery!(env)) : nothing
    return (sched_fn, hook)
end

# ONE-STEP DEVIATION producer: follow the base policy at every scheduled decision EXCEPT decision
# `branch_t`, where macro `a` is forced. Because the world is deterministic, the terminal outcome of
# this single run IS Q^π(s_{branch_t}, a) exactly. The base policy is canonical for now; swapping in
# the learned policy here is what turns this into DAgger (step 3) with no other change.
episode_prod(branch_t::Int, a::Int; hz_seed = nothing) = (env, ev) -> begin
    ctx = event_context(env, ev); NEV[] += 1
    ctx.type === :reform && return action_to_proposal(ctx, canonical_action(ctx))   # 배경 회복은 평소대로
    (String(ev) in EP_SCHED_NL[]) || return nothing      # 파생 알람 -> NOOP (CASCADE RULE 유지)
    k = (EP_K[] += 1)
    kind, sev = k <= length(EP_SCHED_META[]) ? EP_SCHED_META[][k] : (Symbol(ctx.type), 0.0)
    act = (k == branch_t) ? a : canonical_action(ctx)
    # ---- 위험 시계 arm: 연구 대상 결정(branch_t) 이 일어나는 바로 그 순간 -----------------
    # 이 전까지의 궤적은 모든 팔·모든 rollout 에서 동일하고(결정 이전은 canonical 로 동일하게 흐른다),
    # 이후만 표집된다. 그래야 Q(s_t, a) 이지 상태 평균이 아니다(STEP 2 에서 확립한 조건).
    # 에피소드 모드는 원래 결정론적 MDP 였는데, STEP 1 의 위험 프로세스를 여기 붙이면
    # **순차 커플링 + 확률 전이**가 동시에 있는 진짜 MDP 가 된다.
    (k == branch_t && hz_seed !== nothing) &&
        CB.enable_hazard!(env; params = HZ_PARAMS, seed = hz_seed)
    f = capture_features(env, ctx, kind, sev, SPARES[1])
    # SMDP sojourn: 결정은 사건이 터진 순간에만 일어나고 그 사이 간격은 불규칙하다. 두 결정 사이에
    # 닫힌 노드 수를 남겨 두면, 그것이 곧 "이 개입의 효과가 다음 결정 전에 얼마나 흡수됐는가"의 척도가
    # 된다(τ 가 크면 커플링이 약해 bandit 근사가 맞고, 작으면 MDP 가 필요하다는 실측 신호).
    closed_now = length(env.cache.closed_set)
    push!(TRACE[], (decision_idx = k, macro_taken = act, feats = f, closed_at = closed_now))
    k == branch_t && (FEAT[] = f)                        # run_one 의 fired 판정과 호환되게
    return act == 0 ? nothing : action_to_proposal(ctx, act)
end

# ---- injection per kind (returns (schedule_fn, pre_sim_hook)) ---------------------------
# The completion-guaranteeing fault target (identical to the LLM demo's `_single_solo_fault_target`,
# which COMPLETES): an active robot with EXACTLY ONE remaining non-closed transport-feeding RobotGo
# slot whose team is solo. Deterministic (lowest id). See build_injection for why this matters.
# single_solo_fault_target : 완주가 보장되는 고장 대상 로봇을 고른다 = 남은 운반작업이 "정확히 하나"이고 그 팀이 solo인 로봇.
#   (이런 로봇만 고장내면 spare 가 깨끗한 작업 하나만 물려받아 교착이 안 생기고 빌드가 끝까지 감.) 결정적으로 가장 작은 id 선택.
function single_solo_fault_target(env)
    sched = env.sched; cands = CB.RobotID[]              # 후보 로봇 id 배열
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue
        rid = try CB.entity(n).id catch; nothing end
        rid isa CB.RobotID || continue
        CB._first_pending_assignment(env, rid) === nothing && continue   # pending 작업이 아예 없으면 제외
        n_slots = 0; all_solo = true                    # 이 로봇의 남은 운반작업 수 / 전부 solo팀인지
        for w in Graphs.vertices(sched)
            w in env.cache.closed_set && continue
            m = CB.get_node_from_id(sched, CB.get_vtx_id(sched, w))
            m isa CB.RobotGo || continue
            (try CB.entity(m).id == rid catch; false end) || continue   # 같은 로봇 것만
            outs = Graphs.outneighbors(sched, w); isempty(outs) && continue
            fn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, outs[1]))
            fn isa CB.FormTransportUnit || continue     # 다음이 운반팀 형성인 슬롯만 셈
            n_slots += 1
            (try length(CB.robot_team(CB.entity(fn))) == 1 catch; false end) || (all_solo = false)   # 팀 크기 1(solo)이 아니면 탈락
        end
        (n_slots == 1 && all_solo) && push!(cands, rid)  # 정확히 1개 + 전부 solo → 후보 등록
    end
    isempty(cands) && return nothing
    return sort(cands, by = r -> r.id)[1]                # 가장 작은 id(결정적 선택)
end

# build_injection : OOD 종류별로 "언제·어떻게 사건을 터뜨릴지"를 담은 (schedule 함수, pre_sim 훅) 짝을 만든다.
#   schedule 함수 = 시뮬 시작 전 OOD 발화 예약. pre_sim 훅 = 시뮬 전 사전 설정(battery만 사용, 나머지는 nothing).
function build_injection(kind::Symbol, severity, seed; fire_at::Int = 0)
    # fire_at>0 이면 그 목표점 위쪽으로만 짧게 재시도(= 발화 시점이 instance 차원).
    # fire_at=0 이면 예전 그대로 그 종류의 FIRE_POINTS 사다리.
    fire = fire_ladder(kind, fire_at)                    # 이 instance 의 발화 시점(closed 노드 수) 목록
    if kind === :fault
        sched_fn = () -> begin
            fired = Ref(false)                          # 한 번만 터지게 하는 플래그 상자
            # Target a robot with EXACTLY ONE remaining solo transport task. The spare then inherits a
            # single clean task, `_serialize_spare_frontiers!` adds ZERO serialization gates, and the
            # documented multi-task cyclic-cargo wedge cannot arise -> the build COMPLETES, like the
            # no-fault control (this is the LLM demo's `_single_solo_fault_target`, which completes).
            # The old `fault_action(safe=true)` only required a solo TEAM, not a single TASK, so it could
            # kill a robot owing several tasks -> spare over-subscribed -> Replace stalls near completion
            # (191/305). clear=false keeps the dead body in place, as the completing demo does.
            clear = get(ENV, "DS_FAULT_CLEAR", "0") == "1"   # clear=참이면 고장난 로봇 시신을 치움(장애물로 안 남김)
            # `single_solo` (exactly-one task) matches the LLM demo's completion-guaranteeing picker but
            # rarely has a candidate at these early points; fall back to the looser solo-frontier picker
            # (a solo transporter with pending work) that the demo actually fires with. DS_FAULT_PICK
            # selects: "single" | "solo" (default: try single, else solo).
            # DS_FAULT_PICK="any" (2026-08-04 추가) — 안전 술어를 **끄고** 아무 활성 로봇이나 고장낸다.
            #
            # 왜 이 옵션이 필요한가. 위 두 피커는 closed>=80 에서 후보를 하나도 못 찾는다(실측:
            # oracle/out/fire_probe.csv). 그래서 후반 fault 라벨이 원리적으로 안 만들어진다. 그런데
            # 그 술어들이 막으려는 것은 "현실성"이 아니라 **엔진 어서션**이다: 다중로봇 운반팀의
            # 공동 운반자를 고장내면 route_planning.jl 의
            #     @assert has_edge(scene_tree, agent, robot_id)   (apply_cmd!(::FormTransportUnit))
            # 가 매 스텝 터져 런 자체가 죽는다(라벨이 안 나온다).
            #
            # 그 술어는 HOT_SWAP(정체성 보존 교체) 이전 시대의 가드다. HOT_SWAP 은 id 를 유지하고
            # 본체만 창고에서 갈아끼우므로 scene-tree 간선이 끊기지 않을 수 있다 = 어서션이 안 터질
            # 수 있다. "any" 는 그 가설을 **측정으로** 확인하기 위한 스위치다. 통과하면 pick_solo_* 는
            # 고칠 대상이 아니라 없앨 대상이고, 터지면 팀 해체·재결성(Route 1)이 필요하다는 뜻이다.
            #
            # 주의: 이 모드는 라벨을 망가뜨릴 수 있다(스페어 과다구독 -> Replace 미완주 -> 오라클이
            # Replace 를 나쁜 매크로로 잘못 배운다). 검증 실험 전용이며, 기본값은 그대로 "auto" 다.
            # DS_FAULT_PICK="hotswap" (2026-08-05 추가) — HOT-SWAP 세계 전용의 넓은 안전 피커만 쓴다.
            #
            # 왜. 위 세 피커는 전부 `_first_pending_assignment`(= 깨끗한 작업 경계에 서 있는 로봇)를
            # 요구하는데, 빌드가 굴러가기 시작하면 로봇들은 운반 사슬 안에 들어가 그 경계를 스쳐
            # 지나갈 뿐이라 closed>=80 에서는 후보가 **하나도** 안 나온다(실측 fire_probe.csv).
            # 그래서 fault 는 항상 closed∈{50,58} 에서만 터졌고, 그게 progress 축이 점 하나가 된
            # 직접 원인이다(LABELING_MANUAL §6).
            #
            # 그 술어가 막으려던 것은 스케줄 재각인 경로의 has_edge 어서션인데, 정체성 보존 HOT-SWAP 은
            # id 를 유지한 채 본체만 갈아끼우므로 넘길 엣지가 없고 운반 도중에도 안전하다 —
            # 엔진이 이미 같은 예외를 두 곳(hazard.jl `_hz_safe_target`, battery.jl)에서 쓰고 있다.
            # `CB.pick_hotswap_fault_target` 이 그 조건의 피커 형태다.
            pick = get(ENV, "DS_FAULT_PICK", "auto")     # "single" | "solo" | "any" | "hotswap" | 기본 "auto"
            hot_swap_on = get(ENV, "DS_HOTSWAP", get(ENV, "HOT_SWAP", "0")) == "1"
            act = e -> begin                             # e(환경)를 받아 실제로 고장을 일으키는 액션 함수
                fired[] && return nothing                # 이미 터졌으면 무시
                if pick == "any"                         # 안전 술어 없이: 활성 로봇 아무나(fault_robot! 내부 _pick_active_robot)
                    nl = CB.fault_action(; safe = false, obstacle = false, clear = clear)(e)
                    return nl === nothing ? nothing : (fired[] = true; nl)
                end
                tgt = pick in ("solo", "hotswap") ? nothing : single_solo_fault_target(e)   # 우선 "정확히 1작업" 대상 시도
                tgt === nothing && !(pick in ("single", "hotswap")) &&
                    (tgt = try CB.pick_solo_fault_target(e) catch; nothing end)      # 없으면 느슨한 solo 대상
                tgt === nothing && !(pick in ("single", "hotswap")) &&
                    (tgt = try CB.pick_solo_frontier_target(e) catch; nothing end)   # 그것도 없으면 solo frontier 대상
                # 마지막 폴백(hot-swap 세계에서만): 위 피커들이 전부 비는 중반 이후를 담당한다.
                # "auto" 에서는 **기존 피커가 실패했을 때만** 쓰이므로, 기존 초반 덤프의 대상 선택은
                # 한 글자도 바뀌지 않는다(재현성 유지). "hotswap" 이면 처음부터 이것만 쓴다.
                tgt === nothing && (pick == "hotswap" || (pick == "auto" && hot_swap_on)) &&
                    (tgt = try CB.pick_hotswap_fault_target(e) catch; nothing end)
                tgt === nothing && return nothing
                nl = CB.fault_action(; target = tgt, obstacle = false, clear = clear)(e)   # 실제 고장 실행 → NL 반환
                nl === nothing ? nothing : (fired[] = true; nl)   # 성공하면 fired 표시하고 NL 반환
            end
            for c in fire; CB.schedule_ood_at_closed!(c, act); end   # 각 발화 시점 c 에 이 액션을 예약
        end
        return (sched_fn, nothing)                       # fault 는 pre_sim 훅 불필요 → nothing
    elseif kind === :faultidle                          # harmless breakdown (victim owns no work)
        sched_fn = () -> begin
            fired = Ref(false)
            tf = fault_idle_action()                     # 무해한 희생양 고장 액션
            act = e -> fired[] ? nothing : (nl = tf(e); nl === nothing ? nothing : (fired[] = true; nl))
            for c in fire; CB.schedule_ood_at_closed!(c, act); end
        end
        return (sched_fn, nothing)
    elseif kind === :zoneharm                           # harmless zone (over a FINISHED staging area)
        sched_fn = () -> begin
            fired = Ref(false)
            act = e -> fired[] ? nothing :
                (nl = place_harmless_zone!(e); nl === nothing ? nothing : (fired[] = true; nl))   # 빈 바닥에 무해 zone
            for c in fire; CB.schedule_ood_at_closed!(c, act); end
        end
        return (sched_fn, nothing)
    elseif kind === :zone
        sched_fn = () -> begin
            fired = Ref(false)
            zf = CB.zone_action(key = :zone_ds)          # 기본 zone 액션(navigator 제공)
            act = e -> fired[] ? nothing : (nl = zf(e); nl === nothing ? nothing : (fired[] = true; nl))
            for c in fire; CB.schedule_ood_at_closed!(c, act); end
        end
        return (sched_fn, nothing)
    elseif kind === :zoneblk
        off = Float64(severity)                           # severity carries the zone-offset (severity knob)
        sched_fn = () -> begin
            fired = Ref(false)
            act = e -> fired[] ? nothing : (nl = place_blocking_zone!(e; offset = off); nl === nothing ? nothing : (fired[] = true; nl))   # 실제 막는 zone
            for c in fire; CB.schedule_ood_at_closed!(c, act); end
        end
        return (sched_fn, nothing)
    elseif kind === :battery
        # severity = target post-drop SoC. The ladder is designed to STRADDLE the stall boundary
        # (2026-08-05 redesign, see `_arm_battery!`):
        #   0.02 < thr        -> immediate stall (robot dead where it stands) -> intervention needed
        #   0.3  in (thr,hi)  -> DERATED: slower but still working -> intervention is a cost/benefit call
        #   0.5  >= hi        -> effectively nominal -> intervening is waste (NOOP)
        # soc_drop is applied from soc0=1.0 -> drop = 1 - target.
        drop = clamp(1.0 - Float64(severity), 0.1, 1.0)   # severity=목표 잔량 → 떨어뜨릴 양(=1-목표), 0.1~1.0로 제한
        sched_fn = () -> begin
            fired = Ref(false)
            # DS_BSOC_MODE=abs(기본): 결과 SoC 를 severity 로 **확정**한다. 뺄셈(drop)이면 사건
            # 시점까지의 소모분만큼 사다리 칸이 아래로 밀려, 설계한 정지/감속 경계를 벗어난다
            # (실측: 목표 0.02 인데 기록 soc=0.0). "drop" 을 주면 예전 뺄셈 경로로 되돌아간다.
            bf = get(ENV, "DS_BSOC_MODE", "abs") == "abs" ?
                 CB.battery_action(soc_target = Float64(severity)) :
                 CB.battery_action(soc_drop = drop)      # SoC 를 drop 만큼 떨어뜨리는 액션
            act = e -> fired[] ? nothing : (nl = bf(e); (nl === nothing || isempty(nl)) ? nothing : (fired[] = true; nl))
            for c in fire; CB.schedule_ood_at_closed!(c, act); end
        end
        # enable_battery! (accounting+objective+stall gate) THEN arm the stall/derate so the SoC band
        # actually changes what the robot can do. This is what makes battery CONSEQUENTIAL.
        return (sched_fn, env -> _arm_battery!(env))     # battery 만 훅을 함께 반환
    end
    error("unknown kind $kind")                          # 위 종류 어디에도 안 맞으면 오류
end

# run_with_stack : 함수 f 를 "스택 크기를 크게 키운 별도 Task"에서 실행(깊은 재귀로 스택 넘침 방지). f 의 결과를 반환.
#   ccall = C 함수 직접 호출(여기선 큰 스택의 새 Task 생성). 예외가 나면 출력 후 다시 던짐.
function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)   # 결과/에러/완료 플래그 상자
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)   # 큰 스택 Task 생성
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end   # 실행 예약 후 끝날 때까지 대기
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))   # 에러 있으면 표시 후 재던짐
    return res[]
end

# one full sim: plug `prod` into the respec seam, inject (unless control), read labels + captured feats
# run_one : 시뮬레이션 한 판을 처음부터 끝까지 돌린다. prod=꽂을 정책, inject=OOD를 실제로 예약할지 여부.
#   반환 = named tuple(완주 여부·닫힌수·makespan·측정시간·최소SoC·특징 등 라벨 한 세트).
function run_one(prod; kind, severity, seed, n_spare, inject::Bool, plan = nothing, fire_at::Int = 0)
    FEAT[] = nothing; NEV[] = 0                          # 판마다 전역 상태 초기화
    STUDIED_AGENT[] = nothing                            # 캐스케이드 판정용 대상 로봇도 판마다 초기화
    try CB.disable_hazard!() catch end                   # 이전 판의 위험 시계 + 스텝 훅 원복(MC 모드 전용)
    NOMINAL_FEAT[] = nothing                             # nominal 캡처 상자도 판마다 비운다
    # 에피소드 모드 전역 상태도 판마다 비운다(plan=nothing 이면 아래에서 아무도 안 읽으므로 무해).
    EP_SCHED_NL[] = String[]; EP_SCHED_META[] = Any[]; TRACE[] = Any[]; EP_K[] = 0
    PROBE_TRACE[] = Any[]
    CB.RESPEC_ENABLED[] = true                           # 개입(respec) 기능 켜기
    # 이전 판에서 남은 잔여 상태를 전부 청소(각 clear 함수를 이름으로 찾아 호출). 없으면 조용히 넘어감.
    for f in (:clear_ood_schedule!, :clear_restriction_zones!, :clear_spare_pools!, :clear_faulted_robots!,
              :clear_recovery_spares!, :clear_ood_truth_log!, :clear_wedge_edges!, :clear_stalled_robots!)
        try getproperty(CB, f)() catch end               # getproperty(CB, :foo) = CB.foo (심볼로 함수 접근)
    end
    # Reform (the background team/nav recovery) must fire as often as it does in the demos that are known
    # to complete. At 400 the recovery reacts so slowly that a mid-build Replace wedges the endgame — that
    # is where "Replace = 172 closed, INCOMPLETE" came from. The LLM replace demo has used 120 since
    # 2026-07-09 and completes; the oracle was never updated to match, so every label was measured in a
    # slow-recovery world the demos do not live in. Same knob, same value, everywhere.
    try CB.set_reform_interval!(parse(Int, get(ENV, "DS_REFORM", "120"))) catch end   # 배경 재정렬 주기(데모와 같은 120으로 맞춤)
    # DS_HOTSWAP=1 (or HOT_SWAP=1): enact ReplaceAgent as an identity-preserving depot hot-swap (no
    # schedule re-stamp), so the fault Replace label is measured in the SAME completing world the demo
    # runs. Without this the distributed re-stamp leaves Replace INCOMPLETE (~172-210) and mislabels the
    # macro. Must match the demo's HOT_SWAP setting exactly (see demo_respec_replace_anim.jl / stream demo).
    if get(ENV, "DS_HOTSWAP", get(ENV, "HOT_SWAP", "0")) == "1"   # hot-swap 켜기: Replace 를 창고에서 정체성 유지 교체로 실행
        try CB.set_hot_swap!(enabled = true, mode = Symbol(get(ENV, "HOT_SWAP_MODE", "via_depot"))) catch end
    else
        try CB.set_hot_swap!(enabled = false) catch end
    end
    try CB.BATTERY_FLEET[] = nothing catch end                    # 배터리 상태 초기화
    try CB.set_battery_stall!(enabled = false) catch end          # reset stall gate between runs
    try CB.set_battery_derate!(enabled = false) catch end         # reset graded derate band too
    CB.set_respec_producer!(prod)                                 # 개입 지점(seam)에 정책 prod 를 꽂음
    # plan 이 있으면 에피소드(다중 사건) 예약, 없으면 기존 단일 사건 예약. 기본값 nothing = 기존 동작.
    sched_fn, hook = plan === nothing ? build_injection(kind, severity, seed; fire_at = fire_at) :
                                        build_episode_injection(plan)
    # the pre_sim setup (e.g. enable_battery!) applies to BOTH the OOD runs AND the control, so the
    # control is the SAME world minus the fired OOD (fair admissibility). `inject` only gates whether
    # the OOD trigger is actually scheduled. (hook is `nothing` for fault/zone -> inert there.)
    inject && sched_fn()                                          # inject 가 참일 때만 OOD 발화를 예약(control 은 안 함)
    # control 판(=교란 없는 세계)에서만 nominal 관찰 지점을 심는다. OOD 판에는 절대 넣지 않는다:
    # 그러면 같은 판에서 두 종류의 캡처가 경쟁하게 되고, 교란 런의 특징이 오염된다.
    (!inject && NOMINAL_ARM) && schedule_nominal_probe!(n_spare; at = fire_at)
    t_start = time()   # wall-clock cost of ONE true-planner label (MILP assignment + full RVO sim)
    # 스택 크기는 DS_STACK 으로 조절(기본값 2GB = 기존 동작 그대로).
    # 왜 조절이 필요한가: 이 스택은 판 하나마다 통째로 잡히므로, 라벨러를 N개 병렬로 돌리면 스택만 N×2GB다.
    # 16GB 머신에서 4병렬이 OutOfMemoryError 로 죽은 원인이 바로 이것. 낮추기 전엔 반드시 1인스턴스 스모크로
    # StackOverflowError 가 안 나는지 확인할 것(깊은 재귀 방지가 이 큰 스택의 존재 이유다).
    res = run_with_stack(parse(Int, get(ENV, "DS_STACK", "2000000000"))) do   # 큰 스택에서 진짜 시뮬 한 판(tractor, 로봇 10대) 실행
        CB.run_lego_demo(; ldraw_file = "tractor.mpd", num_robots = 10, assignment_mode = :greedy,
            milp_optimizer = :highs, optimizer_time_limit = 60, log_level = (get(ENV,"DS_LOG","warn")=="info" ? Logging.Info : Logging.Warn),
            max_num_iters_no_progress = NOPROG, rvo_flag = true, tangent_bug_flag = true,   # RVO=충돌회피 켜기(끄면 정답이 뒤집힘)
            dispersion_flag = true, n_spare_per_pool = n_spare, save_animation = false,
            open_animation_at_end = false, write_results = false, overwrite_results = true,
            return_env_before_sim = false, pre_sim_hook = hook,   # 위에서 만든 pre_sim 훅(battery만 유효)
            rng = Random.MersenneTwister(seed))                   # seed 로 난수 고정(재현성)
    end
    label_seconds = time() - t_start                              # 이 라벨 한 개를 얻는 데 걸린 실제 벽시계 시간
    # efficiency-axis label: worst per-robot SoC at end (battery margin). NaN when battery is off.
    min_soc = try
        fl = CB.BATTERY_FLEET[]; fl === nothing ? NaN : Float64(CB.battery_report(fl).min_soc)   # 끝에서 가장 낮은 로봇 잔량
    catch; NaN end
    n_stalled = try length(CB.stalled_robots()) catch; 0 end      # 끝에 멈춰버린 로봇 수
    hz = try CB.hazard_report() catch
        (n_break=0, n_cell=0, n_zone=0, n_break_pending=0, capped=false, t=0.0)
    end                                                           # 사후(post-decision) 고장 통계
    try CB.disable_hazard!() catch end                            # 훅 원복(다음 판 오염 방지)
    CB.clear_respec_producer!(); CB.RESPEC_ENABLED[] = false      # 개입 정책 제거 + 기능 끄기(다음 판 위해 정리)
    env   = res isa Tuple ? res[1] : res                          # run_lego_demo 반환이 (env, stats)일 수도, env 단독일 수도
    stats = res isa Tuple ? res[2] : Dict()
    return (
        complete = CB.project_complete(env),                     # 빌드 완주 여부(가장 중요한 라벨)
        closed   = length(env.cache.closed_set),                 # 닫힌 노드 수
        total    = length(CB.get_nodes(env.sched)),              # 전체 노드 수
        makespan = (try Float64(get(stats, :Makespan, NaN)) catch; NaN end),   # 실제 makespan(총 소요시간)
        label_seconds = label_seconds,
        min_soc  = min_soc,
        n_stalled = n_stalled,
        feats    = FEAT[],                                       # capture_features 로 담아둔 결정 순간 특징
        fired    = FEAT[] !== nothing,                           # OOD 가 실제로 터졌는지(특징이 채워졌으면 참)
        nominal_feats = NOMINAL_FEAT[],                          # control 판에서만 채워짐(교란 없는 상태)
        hz_break = hz.n_break, hz_cell = hz.n_cell, hz_zone = hz.n_zone,   # 사후 고장 수(rollout 이 다른 미래를 겪었다는 증거)
        hz_pending = hz.n_break_pending, hz_capped = hz.capped, hz_sim_s = hz.t,
    )
end

# ---- JSON writer (one row per (instance, macro)) ---------------------------------------
# 외부 JSON 라이브러리 없이 직접 JSONL 한 줄을 만드는 3개의 작은 도우미.
jesc(s) = replace(replace(String(s), "\\" => "\\\\"), "\"" => "\\\"")   # 문자열 안 역슬래시/따옴표 escape
# jval : 값 하나를 JSON 표기로. Bool→true/false, 문자열→따옴표, 배열→[...], 무한/NaN 은 문자열로(JSON 엔 없음).
jval(x) = x isa Bool ? (x ? "true" : "false") :
          x isa AbstractString ? "\"$(jesc(x))\"" :
          x isa AbstractVector ? "[" * join(jval.(x), ",") * "]" :   # jval.(x) = 각 원소에 jval 적용(브로드캐스트)
          x isa Real ? (isfinite(x) ? string(x) : "\"$(x)\"") : "\"$(x)\""
jrow(d) = "{" * join(["\"$(k)\":$(jval(v))" for (k,v) in d], ",") * "}"   # (키,값) 쌍들을 {"k":v,...} 한 줄로

# main : 전체 흐름 — instance 목록을 만들고, 각각 control 1판 + 매크로 5판을 돌려 JSONL 로 기록.
"""
DS_RESUME=1 : 출력 파일에 이미 있는 instance 는 건너뛰고 이어서 쓴다(append).

왜 필요한가 -- 라벨 생성은 시간 단위로 걸린다(control 1판 약 212초 × 60판 ≈ 3.5시간). 그 사이에
셸이 끝나거나 프로세스가 죽으면, 재개 기능이 없을 때는 **이미 만든 것까지 버리고 처음부터** 다시
돌게 된다. 실제로 첫 시도가 그렇게 0행으로 끝났다. 각 행은 즉시 flush 되므로 죽는 순간까지의
결과는 파일에 남아 있고, 남은 것만 이어서 하면 된다.
"""
const RESUME = get(ENV, "DS_RESUME", "0") == "1"

"출력 파일에서 이미 완료된 instance id 집합을 읽는다(없으면 빈 집합)."
function done_instances(path::AbstractString)
    # COMPLETE means all |MACROS| arms are present, not "at least one row".
    # A crash mid-instance (OutOfMemoryError is routine here -- run_with_stack takes a 2 GB stack per
    # run) leaves 1-4 arms on disk. Treating that as done made DS_RESUME skip it forever, so the
    # instance stayed PARTIAL and was silently dropped downstream, where every analysis keeps only
    # instances with a full macro sweep (`len(g) == 5`). Measured on the 2026-07-31 expansion:
    # 8 of 44 instances were lost this way. Counting arms makes resume re-run exactly those.
    # 한국어: "행이 하나라도 있으면 완료"로 보면 크래시로 끊긴 instance 를 영영 건너뛴다. 분석은 5개
    #   arm 이 다 있는 instance 만 쓰므로 그건 조용히 버려진다. arm 을 세어 미완성은 다시 돌게 한다.
    # 기대 arm 수는 **이번 실행이 실제로 쓰는 팔의 수**여야 한다 (2026-08-04 수정).
    #   전에는 무조건 length(MACROS)=5 였다. DS_MACROS=0 (서술자만 뽑는 TIER A) 로 돌리면 instance 당
    #   행이 1개뿐이라 5 를 넘길 수 없고, 그래서 **어떤 instance 도 done 으로 안 잡혀** RESUME 이
    #   전부 다시 돌린다. 실측(2026-08-04): 이어받기 실행이 이미 끝난 12 instance 를 재실행해
    #   중복 행 4개를 append 했다. 값은 컴퓨트만 낭비하는 게 아니라, "이어받기가 되고 있다"고
    #   믿게 만들어 진행 상황 판단까지 틀리게 한다.
    #
    #   DS_VALID_ONLY 는 instance 마다 팔 수가 달라(2~3) **미리** 알 수 없다. 하지만 각 행이 그때
    #   실제로 돈 팔 수를 `arms_labeled` 로 함께 적고 있으므로, 파일에서 instance 별로 그 값을 읽어
    #   기대치로 쓴다 (2026-08-05). 이게 없으면 VALID_ONLY 실행은 expected=5 를 절대 못 채워
    #   **이어받기가 이미 끝난 instance 를 전부 다시 돈다** — 실측: OOM 재개 런이 f58/f100/f140 을
    #   재실행해 12분을 버렸다. `arms_labeled` 가 없는 옛 덤프는 예전 규칙으로 폴백한다.
    expected_arms = isempty(MACRO_SUBSET) ? length(MACROS) : length(MACRO_SUBSET)
    counts = Dict{String,Int}()
    per_inst_expected = Dict{String,Int}()      # instance -> 그 instance 가 실제로 돌아야 하는 팔 수
    nominal = Set{String}()
    isfile(path) || return Set{String}()
    for line in eachline(path)
        isempty(strip(line)) && continue
        v = _jfield(line, "instance")
        v === nothing && continue
        if endswith(v, "_nominal")
            push!(nominal, v)
        else
            counts[v] = get(counts, v, 0) + 1
            al = _jfield(line, "arms_labeled")
            if al !== nothing
                n = try parse(Int, al) catch; 0 end
                n > 0 && (per_inst_expected[v] = n)
            end
        end
    end
    done = Set{String}(k for (k, n) in counts if n >= get(per_inst_expected, k, expected_arms))
    union!(done, nominal)          # nominal 행은 instance 당 1개가 정상
    return done
end

# ---- episode driver: one row per (episode, decision t, branched macro a) ----------------
# 각 행이 곧 전이 하나다: s_t = 결정 t 의 상태, a = 거기서 강제한 매크로, next_* = 그 선택 뒤 도달한
# 다음 결정의 상태(없으면 done=true). 이 4-튜플이 FQI 타깃 r + max_a' Q(s',a') 의 재료 전부다.
function run_episodes(io)
    n_rows = 0; n_probe = 0
    # probe 궤적은 별도 파일로. 한 런 안의 연속 probe 가 곧 고정 스텝 전이 (s_t, NOOP, s_{t+1}) 다.
    pio = open(replace(OUTFILE, r"\.jsonl$" => "") * ".probes.jsonl", RESUME ? "a" : "w")
    for seed in SEEDS
        plan = episode_plan(seed)
        eid  = "ep_s$(seed)_M$(EPISODE_N)"
        println("[episode] $(eid) plan = " *
                join(["@closed$(c):$(k)(sev$(round(s, digits=2)))" for (c, k, s) in plan], "  "))
        # ---- 결정 t 에서 라벨링할 매크로 목록 -------------------------------------------
        # VALID_ONLY 면 계획(plan)에 적힌 kind/severity 로 valid 집합을 **직접 계산**한다.
        # (단일사건 모드처럼 탐색 판을 한 번 돌릴 필요가 없다 — 계획을 미리 알고 있으므로.)
        # DS_EP_MACROS="0,5" 처럼 주면 valid 계산을 건너뛰고 **그 목록만** 라벨링한다.
        # 조합 팔(A1 스모크)처럼 valid 표에 없는 팔을 일부러 돌려보기 위한 통로다.
        # 설정하지 않으면 아래 로직이 그대로 돌아 기존 생성 경로는 한 글자도 바뀌지 않는다.
        ep_macros = function (t)
            ov = get(ENV, "DS_EP_MACROS", "")
            isempty(ov) || return [parse(Int, strip(s)) for s in split(ov, ",")]
            VALID_ONLY || return MACROS
            t <= length(plan) || return MACROS
            (_, k, sev) = plan[t]
            k === :fault && return [0, 1]
            # zone 팔은 shim 의 _zone_arms() 단일 출처를 따른다(기본 [0,7]=NOOP/RelocateBuild).
            # 여기 [0,3] 을 하드코딩해 두면 shim 과 어긋나 "덤프에는 3, 실행은 7" 같은 조용한 불일치가 난다.
            #
            # 2026-08-05(STEP 2): shim 의 `valid_actions(:zone)` 은 이제 **결정 시점의 기하**로 정해진다
            # (`zone_diagnosis`: 옮길 수 있을 때만 3, 벗어날 Δ 가 있을 때만 7). 여기 이 목록은 그보다
            # 앞선 시점 — 판을 돌리기 전, 계획만 보고 정하는 **롤아웃 후보**라 기하를 알 수 없다. 그래서
            # 둘은 역할이 다르며, 어긋난 것이 아니다: 후보로 돌린 팔이 그 시점에 행동 불가였다면
            # `action_to_proposal` 이 NOOP 팔로 접고 `valid_mask` 에 그 사실이 그대로 남는다.
            # 3(ForbidZone)까지 롤아웃해 라벨을 얻고 싶으면 DS_EP_MACROS="0,3,7" 로 후보를 넓힌다
            # (STEP 6 의 가지별 격자가 그렇게 한다).
            k in (:zoneblk, :zonecore) && return _zone_arms()
            if k === :battery
                thr = try Float64(CB.REPLACE_SOC_THRESHOLD[]) catch; 0.2 end
                return sev <= thr ? [0, 1] : [0, 2]
            end
            return MACROS
        end
        for t in 1:EPISODE_N, a in ep_macros(t), rk in 1:MC_K
            hz_seed = MC_K > 1 ? HZ_SEED0 + rk : nothing
            r  = run_one(episode_prod(t, a; hz_seed = hz_seed); kind = :fault, severity = 1.0,
                         seed = seed, n_spare = SPARES[1], inject = true, plan = plan)
            tr = TRACE[]                                  # run_one 이 방금 채운 궤적(다음 판 시작 때 비워짐)
            if length(tr) < t
                # 앞선 결정의 결과로 빌드가 먼저 끝났거나 사건이 안 터져 결정 t 에 도달하지 못한 경우.
                # 라벨이 없는 것이 아니라 "그 결정이 존재하지 않는" 것이므로 행을 쓰지 않고 기록만 남긴다.
                @printf("     t=%d %d:%-12s SKIP (only %d decision(s) reached)\n",
                        t, a, ACTION_NAME[a], length(tr))
                continue
            end
            s_t = tr[t].feats
            s_n = length(tr) >= t + 1 ? tr[t + 1].feats : nothing
            row = Pair{String,Any}[
                "instance"=>"$(eid)_t$(t)", "episode"=>eid, "decision_idx"=>t,
                "n_decisions"=>length(tr), "seed"=>seed, "n_spare_cfg"=>SPARES[1],
                # --- MC(확률 전이) 메타. DS_MC_K=1 이면 rollout=0, hz_*=0 이라 기존과 구분된다 ---
                "rollout"=>(MC_K > 1 ? rk : 0), "hz_seed"=>(hz_seed === nothing ? -1 : hz_seed),
                "hz_break"=>r.hz_break, "hz_cell"=>r.hz_cell, "hz_zone"=>r.hz_zone,
                "hz_pending"=>r.hz_pending, "hz_capped"=>r.hz_capped, "hz_sim_s"=>r.hz_sim_s,
                "macro"=>a, "macro_name"=>ACTION_NAME[a], "macro_cost"=>MACRO_COST[a],
                "fired"=>r.fired, "done"=>(s_n === nothing),
                "closed_at_decision"=>tr[t].closed_at,
                # τ = 이 결정에서 다음 결정까지 닫힌 노드 수. 다음 결정이 없으면 -1(종단).
                "tau_to_next"=>(s_n === nothing ? -1 : tr[t + 1].closed_at - tr[t].closed_at),
                "complete"=>r.complete, "closed"=>r.closed, "total"=>r.total,
                "makespan"=>r.makespan, "label_seconds"=>r.label_seconds,
                "min_soc"=>r.min_soc, "n_stalled"=>r.n_stalled,
                # control 은 에피소드 모드에서 정의되지 않는다(admissibility 는 cost-aware 라벨이 대신함).
                "ctrl_complete"=>false, "ctrl_closed"=>-1, "ctrl_makespan"=>Inf,
            ]
            # ---- 이력 블록 (T2 검정용) ---------------------------------------------------
            # 설계 §3.6 의 T2 = "φ 에 이력을 더하면 결정이 나아지는가". 나아지면 s 는 Markov 가
            # 아니다. 그러려면 φ 와 **분리된** 이력 채널이 있어야 하는데 지금까지 없었다.
            # 여기 담는 값은 전부 결정 t 시점에 이미 관측 가능한 것들이다(미래 누출 아님):
            # 직전 결정에서 무엇을 골랐고, 그 뒤 얼마나 진행됐고, 지금까지 몇 번 개입했는가.
            _pm = t >= 2 ? tr[t-1] : nothing
            _pf = _pm === nothing ? nothing : _pm.feats
            push!(row, "hist_n_prior"       => t - 1)
            push!(row, "hist_prev_macro"    => (_pm === nothing ? -1 : _pm.macro_taken))
            push!(row, "hist_prev_kind"     => (_pf === nothing ? "none" : String(_pf.kind)))
            push!(row, "hist_prev_closed"   => (_pm === nothing ? -1 : _pm.closed_at))
            push!(row, "hist_dclosed_prev"  => (_pm === nothing ? -1 : tr[t].closed_at - _pm.closed_at))
            push!(row, "hist_prev_severity" => (_pf === nothing ? -1.0 : Float64(_pf.severity)))
            push!(row, "hist_prev_spare"    => (_pf === nothing ? -1 : Int(_pf.spare_count)))
            push!(row, "hist_n_intervened"  => count(x -> x.macro_taken != 0, tr[1:max(0, t-1)]))
            push!(row, "hist_prev_target"   => (_pf === nothing ? -1 :
                                                Int(try _pf.target_id catch; -1 end)))
            for k in propertynames(s_t); push!(row, String(k)=>getproperty(s_t, k)); end
            if s_n !== nothing
                for k in propertynames(s_n); push!(row, "next_" * String(k)=>getproperty(s_n, k)); end
            end
            println(io, jrow(row)); flush(io); n_rows += 1
            for (pi, p) in enumerate(PROBE_TRACE[])
                prow = Pair{String,Any}["episode"=>eid, "branch_t"=>t, "macro"=>a,
                                        "probe_idx"=>pi, "closed_at"=>p.closed_at]
                for k in propertynames(p.raw); push!(prow, String(k)=>getproperty(p.raw, k)); end
                println(pio, jrow(prow)); n_probe += 1
            end
            flush(pio)
            @printf("     t=%d %d:%-12s k=%-2d %s %d/%d mk=%.1f decisions=%d tau=%s brk=%d cell=%d\n",
                    t, a, ACTION_NAME[a], MC_K > 1 ? rk : 0,
                    r.complete ? "Y" : "n", r.closed, r.total, r.makespan, length(tr),
                    (s_n === nothing ? "-" : string(tr[t + 1].closed_at - tr[t].closed_at)),
                    r.hz_break, r.hz_cell)
        end
    end
    close(pio)
    println("[episode] wrote $(n_rows) decision rows + $(n_probe) probe rows")
end

function main()
    mkpath(dirname(OUTFILE))                             # 출력 폴더 없으면 생성
    # 에피소드 모드(결정론적 MDP 데이터). 기본 DS_EPISODE_N=0 이면 이 분기는 없는 것과 같다.
    if EPISODE_N > 0
        io = open(OUTFILE, RESUME ? "a" : "w")
        println("[episode] N=$(EPISODE_N) kinds=$(EP_KINDS) closed∈[$(EP_LO),$(EP_HI)] seeds=$(SEEDS)")
        println("[episode] -> $(OUTFILE)")
        if get(ENV, "DS_DRYRUN", "0") == "1"
            for seed in SEEDS
                println("  [dryrun] s$(seed): " * join(["@closed$(c):$(k)" for (c, k, _) in episode_plan(seed)], " "))
            end
            println("[dryrun] $(length(SEEDS) * EPISODE_N * length(MACROS)) simulation runs total")
            close(io); return
        end
        run_episodes(io); close(io); return
    end
    # RESUME 이면 append 로 열어 기존 행을 보존한다. 아니면 예전처럼 새로 쓴다.
    already = RESUME ? done_instances(OUTFILE) : Set{String}()
    io = open(OUTFILE, RESUME ? "a" : "w")
    RESUME && println("[dataset] resume: $(length(already)) rows already present in $(OUTFILE)")
    println("[dataset] seeds=$(SEEDS) kinds=$(KINDS) spares=$(SPARES) noprog=$(NOPROG) smoke=$(SMOKE)")
    println("[dataset] -> $(OUTFILE)")
    n_rows = 0; n_inst = 0                               # 기록한 줄 수 / instance 수 카운터
    # instance list: fault varies spare levels; zone/battery use default spares=3 and (battery) 2 severities.
    instances = Tuple{Symbol,Float64,Int,Int}[]     # (kind, severity, seed, n_spare)
    for seed in SEEDS, kind in KINDS                      # seed × kind 모든 조합을 돌며 instance 를 채워넣음
        if kind === :fault
            # severity = 1.0: the victim owns a full pending chain (consequential -> Replace).
            # DS_SPARES may include 0 -> no spare exists, so Replace degenerates and the correct macro
            # moves to ReformTeam/NOOP. The model must read `spare_count`, not just the kind.
            for ns in SPARES; push!(instances, (:fault, 1.0, seed, ns)); end   # 예비 수준별로 하나씩
        elseif kind === :faultidle
            # severity = 0.0: SAME kind label, but the victim owns no work -> NOOP is correct.
            for ns in SPARES; push!(instances, (:faultidle, 0.0, seed, ns)); end
        elseif kind === :battery                            # severity 사다리를 훑음(깊은→얕은)
            # severity = post-drop SoC. DS_BSOC sweeps the ladder: deep (stall now -> Replace) ->
            # marginal (runs flat later -> Deprioritize) -> mild (finishes anyway -> NOOP).
            #
            # [2026-08-05] 기본 사다리를 0.05,0.12,0.2,0.3,0.45,0.6 -> **0.02,0.3,0.5** 로 바꿨다.
            # 옛 사다리의 앞 두 칸(0.05/0.12)은 둘 다 정지 임계(0.15) 아래라 **거동이 동일**했고
            # (즉시 정지), 심각도 축이 사실상 한 점이었다. 새 세 칸은 정지 경계를 걸치도록 잡아
            # 로봇의 거동이 실제로 갈린다: 즉시 정지 / 감속하며 계속 일함 / 사실상 무영향.
            # (`_arm_battery!` 의 설계 주석 참조. 옛 사다리는 DS_BSOC 로 언제든 재현 가능.)
            for s in [parse(Float64, x) for x in split(get(ENV, "DS_BSOC", "0.02,0.3,0.5"), ",")]
                push!(instances, (:battery, s, seed, 3))   # 각 목표 SoC 값을 severity 로
            end
        elseif kind === :zoneharm
            push!(instances, (:zoneharm, 0.0, seed, 3))   # zone over a FINISHED staging area -> NOOP
        elseif kind === :zoneblk                            # 겹침 비율(severity)을 훑어 graded OOD 생성
            # sweep the zone-overlap fraction (severity) -> a GRADED consequential OOD (NOOP<->ForbidZone
            # flips with overlap). DS_ZFRACS overrides the default sweep.
            for f in [parse(Float64, s) for s in split(get(ENV, "DS_ZFRACS", "0.5,0.7,0.9,1.1,1.3"), ",")]
                push!(instances, (:zoneblk, f, seed, 3))   # 각 offset 값을 severity 로
            end
        else # zone : one instance at default provisioning
            push!(instances, (kind, 1.0, seed, 3))
        end
    end
    # ---- 발화 시점 차원을 곱한다 (DS_FIRE_GRID) --------------------------------------------
    # 비어 있으면 fire_at=0 인 5-tuple 로만 확장 = 예전과 동일한 목록·동일한 iid.
    # 값이 있으면 (kind,sev,seed,spare) × fire 로 곱해 **진행도별 instance** 를 만든다.
    #
    # 순서: 발화점을 **안쪽** 루프로 둔다(= 한 설정의 진행도 스윕을 먼저 끝낸다). 이 데이터의 목적은
    # `progress` 축에 분산을 넣는 것이므로, 도중에 죽어도 "여러 진행도가 이미 확보된" 상태로 남아야
    # 쓸모가 있다. 반대로 발화점을 바깥 루프로 두면 중단 시 전부 같은 진행도만 남아 고치려던 문제가
    # 그대로 재현된다(8시간 런이 3시간에 죽는 일은 실제로 일어난다).
    fires = isempty(FIRE_GRID) ? [0] : FIRE_GRID
    instances = [(k, sev, sd, sp, f) for (k, sev, sd, sp) in instances for f in fires]
    # DS_INSTANCES_FROM 이 있으면 위에서 만든 목록을 통째로 대체한다(추측 대신 원본 그대로).
    if !isempty(INSTANCES_FROM)
        instances = instances_from_dump(INSTANCES_FROM)
        println("[dataset] instance list taken from $(INSTANCES_FROM): $(length(instances)) instances")
        isempty(instances) && error("no instances parsed from $(INSTANCES_FROM)")
    end
    # DS_SHARD="i/n" : 목록을 n 등분해 i 번째만 처리(병렬 실행용). i 는 1 부터.
    # 왜 이런 방식인가: 프로세스마다 DS_STACK(기본 2GB)을 통째로 잡으므로, 한 프로세스 안에서
    # 스레드를 늘리는 대신 프로세스를 쪼개고 개수를 사람이 통제하는 편이 메모리 사고를 막는다.
    let sh = get(ENV, "DS_SHARD", "")
        if !isempty(sh)
            parts = split(sh, "/")
            i, n = parse(Int, parts[1]), parse(Int, parts[2])
            instances = instances[i:n:end]               # 라운드로빈 = 종류가 골고루 섞임
            println("[dataset] shard $(i)/$(n): $(length(instances)) instances")
        end
    end
    SMOKE && (instances = instances[1:1])                # smoke 모드면 1개만 남김(빠른 점검)
    # DS_DRYRUN=1 : 무엇을 돌릴 예정인지만 찍고 끝낸다. 몇 시간짜리 런을 시작하기 전에 목록이
    # 맞는지 확인하는 용도 -- 목록이 어긋난 걸 3시간 뒤에 발견하는 것보다 낫다.
    if get(ENV, "DS_DRYRUN", "0") == "1"
        local arms = isempty(MACRO_SUBSET) ? MACROS : MACRO_SUBSET
        println("[dryrun] would run $(length(instances)) instances "
                * (NOMINAL_ONLY ? "(control only, no macros)" : "(control + $(length(arms)) macros each)"))
        for (kind, severity, seed, n_spare, fire_at) in instances
            println("  " * instance_id(kind, severity, seed, n_spare, fire_at))
        end
        n_runs = length(instances) * (NOMINAL_ONLY ? 1 : (NOCTRL ? 0 : 1) + length(arms))
        println("[dryrun] $(n_runs) simulation runs total")
        close(io); return
    end

    for (kind, severity, seed, n_spare, fire_at) in instances   # 만들어둔 instance 들을 하나씩 처리
        n_inst += 1
        iid = instance_id(kind, severity, seed, n_spare, fire_at)   # 사람이 읽을 instance id 문자열
        # 이미 만들어둔 것은 건너뛴다. nominal 행은 iid*"_nominal" 로 저장되므로 그 이름으로 확인.
        if RESUME && ((NOMINAL_ONLY && (iid * "_nominal") in already) || (!NOMINAL_ONLY && iid in already))
            println("[$(n_inst)] $(iid)  SKIP (already done)")
            continue
        end
        # control (no OOD) for admissibility, at the same build/spares. DS_NOCTRL=1 skips it: the
        # cost-aware label (GRADED_OOD_DESIGN.md §3) keeps every instance, so no admissibility test is
        # needed and the control is 1/6 of the compute. The ctrl_* columns then carry a sentinel.
        ctrl = NOCTRL ?                                    # DS_NOCTRL=1 이면 control 판을 건너뛰고 sentinel 값 사용
            (complete=false, closed=-1, total=-1, makespan=Inf, feats=nothing, fired=false,
             nominal_feats=nothing, label_seconds=NaN, min_soc=NaN, n_stalled=0) :
            run_one(canonical_bg; kind=kind, severity=severity, seed=seed, n_spare=n_spare,
                    inject=false, fire_at=fire_at)         # OOD 없는 정상 판(관찰 지점도 같은 진행도)
        @printf("[%d] %-28s CONTROL %s %d/%d mk=%.1f\n", n_inst, iid,
                ctrl.complete ? "Y" : "n", ctrl.closed, ctrl.total, ctrl.makespan)

        # ---- nominal arm: control 판 자체를 한 행으로 기록한다 (kind="none", macro=NOOP) --------
        # fired=false 이므로 load_df(fired==True) 를 쓰는 기존 분석은 이 행을 **보지 않는다**.
        # 즉 이 추가는 기존 결과를 바꾸지 않고, M_nominal 만 명시적으로 opt-in 해서 읽는다.
        if NOMINAL_ARM && ctrl.nominal_feats !== nothing
            nrow = Pair{String,Any}[
                "instance"=>iid * "_nominal", "kind"=>"none", "variant"=>"none",
                "severity"=>0.0, "seed"=>seed,
                "n_spare_cfg"=>n_spare, "macro"=>0, "macro_name"=>ACTION_NAME[0], "fired"=>false,
                "complete"=>ctrl.complete, "closed"=>ctrl.closed, "total"=>ctrl.total,
                "makespan"=>ctrl.makespan, "label_seconds"=>ctrl.label_seconds,
                "min_soc"=>ctrl.min_soc, "n_stalled"=>ctrl.n_stalled,
                "ctrl_complete"=>ctrl.complete, "ctrl_closed"=>ctrl.closed,
                "ctrl_makespan"=>ctrl.makespan, "fire_target"=>fire_at,
            ]
            for k in propertynames(ctrl.nominal_feats)
                push!(nrow, String(k)=>getproperty(ctrl.nominal_feats, k))
            end
            println(io, jrow(nrow)); flush(io); n_rows += 1
            @printf("     nominal  captured at closed=%d/%d\n",
                    ctrl.nominal_feats.closed_at_fire, ctrl.nominal_feats.total_nodes)
        end
        # DS_NOMINAL_ONLY=1: 빠진 nominal 행만 채우는 모드 -- 매크로 5판은 기존 파일에 이미 있다.
        if NOMINAL_ONLY
            continue
        end
        # ---- 이 instance 에서 라벨링할 매크로 목록 ---------------------------------------
        # VALID_ONLY 면 "그 사건에서 애초에 실행 가능한 매크로"만 돈다. valid 목록은 사건이 터져야
        # 알 수 있으므로, 항상 유효한 NOOP(=0) 를 먼저 한 판 돌려 그 판이 관측한 valid_mask 를 읽는다.
        # 그 첫 판은 버리지 않고 macro=0 의 rollout 1 로 그대로 기록한다(낭비 없음).
        # DS_MACROS 로 팔을 제한할 수 있다(예: "0" = NOOP 한 판 = 서술자만 필요할 때).
        macro_list = isempty(MACRO_SUBSET) ? MACROS : MACRO_SUBSET
        first_run  = nothing
        if VALID_ONLY
            first_run = run_one(studied_prod(0, kind, severity, n_spare;
                                             hz_seed = MC_K > 1 ? HZ_SEED0 + 1 : nothing);
                                kind=kind, severity=severity, seed=seed, n_spare=n_spare,
                                inject=true, fire_at=fire_at)
            vm = first_run.feats === nothing ? Int[] : collect(first_run.feats.valid_mask)
            macro_list = isempty(vm) ? [0] : sort(unique(Int.(vm)))
            # DS_MACROS 가 있으면 valid 목록과 **교집합**을 쓴다(둘 다 제약이므로 둘 다 지킨다).
            isempty(MACRO_SUBSET) || (macro_list = [a for a in macro_list if a in MACRO_SUBSET])
            isempty(macro_list) && (macro_list = [0])
            @printf("     valid-only: macros=%s (사건이 관측한 valid_mask)\n", string(macro_list))
        end

        for a in macro_list                              # 후보 매크로를 각각 K 판씩 돌림
            for k in 1:MC_K
                # rollout k 는 hazard seed 를 바꿔 **다른 미래**를 표집한다. 같은 k 는 모든 매크로에서
                # 동일한 시드를 쓰므로 팔 사이가 짝지어진다(공통난수, CRN).
                hz_seed = MC_K > 1 ? HZ_SEED0 + k : nothing
                r = (a == 0 && k == 1 && first_run !== nothing) ? first_run :   # 위에서 이미 돌린 판 재사용
                    run_one(studied_prod(a, kind, severity, n_spare; hz_seed = hz_seed);
                            kind=kind, severity=severity, seed=seed, n_spare=n_spare,
                            inject=true, fire_at=fire_at)
                f = r.feats                              # 이 판의 결정 순간 특징
                row = Pair{String,Any}[
                    "instance"=>iid, "kind"=>row_kind(kind), "variant"=>String(kind),  # variant = bookkeeping ONLY (never a feature)
                    "severity"=>severity, "seed"=>seed,
                    "n_spare_cfg"=>n_spare, "macro"=>a, "macro_name"=>ACTION_NAME[a], "fired"=>r.fired,
                    "complete"=>r.complete, "closed"=>r.closed, "total"=>r.total, "makespan"=>r.makespan,
                    "label_seconds"=>r.label_seconds, "min_soc"=>r.min_soc, "n_stalled"=>r.n_stalled,
                    "ctrl_complete"=>ctrl.complete, "ctrl_closed"=>ctrl.closed, "ctrl_makespan"=>ctrl.makespan,
                    # --- MC 라벨링 메타(DS_MC_K=1 이면 rollout=0, hz_* 는 전부 0 = 기존과 구분 가능) ---
                    "rollout"=>(MC_K > 1 ? k : 0), "hz_seed"=>(hz_seed === nothing ? -1 : hz_seed),
                    "hz_break"=>r.hz_break, "hz_cell"=>r.hz_cell, "hz_zone"=>r.hz_zone,
                    "hz_pending"=>r.hz_pending, "hz_capped"=>r.hz_capped, "hz_sim_s"=>r.hz_sim_s,
                    # 요청한 발화점(목표값). 실제 발화점은 closed_at_fire 이고 둘은 다를 수 있다
                    # (배치 경계·대상 부재 재시도). 둘을 같이 남겨야 "왜 여기서 터졌나"가 사후 검증된다.
                    "fire_target"=>fire_at,
                    # 이 행이 **완전한 라벨**인지(매크로 스윕 + control 을 다 돌았는지). DS_MACROS /
                    # DS_NOCTRL 로 줄여 만든 행은 novelty 교정(서술자만 읽음)에는 충분하지만 oracle
                    # 라벨로는 못 쓴다. 표시가 없으면 나중에 두 종류가 섞여 조용히 잘못 쓰인다.
                    "calib_only"=>(!isempty(MACRO_SUBSET) || NOCTRL),
                    "arms_labeled"=>length(macro_list),
                ]
                if f !== nothing                         # 특징이 있으면 named tuple 의 모든 필드를 행에 덧붙임
                    for k2 in propertynames(f); push!(row, String(k2)=>getproperty(f, k2)); end
                end
                println(io, jrow(row)); flush(io); n_rows += 1   # JSONL 한 줄 기록 + 즉시 디스크 반영
                @printf("     %d:%-12s k=%-2d %s %d/%d mk=%.1f fired=%s brk=%d cell=%d\n",
                        a, ACTION_NAME[a], MC_K > 1 ? k : 0,
                        r.complete ? "Y" : "n", r.closed, r.total, r.makespan, r.fired,
                        r.hz_break, r.hz_cell)
            end
        end
    end
    close(io)                                            # 파일 닫기
    println("[dataset] wrote $(n_rows) rows over $(n_inst) instances -> $(OUTFILE)")
end

main()                                                   # 스크립트 실행 시작점(파일을 실행하면 여기서 시작)
