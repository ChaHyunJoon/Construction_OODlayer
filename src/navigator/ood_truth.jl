# ============================================================================
#  [한국어 안내] 이 파일 = OOD "정답(ground-truth) 라벨" 정의소
#  ---------------------------------------------------------------------------
#  프로젝트 역할:
#   · 이 시뮬레이터는 여러 로봇이 협동해 구조물을 짓는 TAMP 시스템이고,
#     도중에 "예상 밖 사건(OOD = Out-Of-Distribution)"이 터진다:
#     로봇 고장(fault) / 통행금지 구역(zone) / 배터리 방전(battery) / 팀 교착(reform).
#   · LLM(또는 다른 컨트롤러)은 자연어(NL) 관찰만 보고 대응책을 내놓는다.
#     그 대응이 "정답"과 얼마나 맞는지 채점하려면, 실제로 무슨 일이 일어났는지
#     아는 "정답 라벨"이 따로 있어야 한다 — 그걸 이 파일이 정의하고 기록한다.
#   · 핵심 원칙: 채널 2개를 절대 섞지 않는다.
#       (1) NL 관찰   -> push_ood! -> LLM 이 봄(모호/불완전).
#       (2) 정답 라벨 -> OOD_TRUTH_LOG -> "채점기"만 봄(LLM 은 절대 못 봄).
#
#  문법 참고(처음 보는 Julia 문법):
#   · abstract type T end / struct S <: T : S 는 추상타입 T 를 상속하는 "구조체(레코드)".
#   · field::Vector{Float64} : 필드에 타입 지정(실수 벡터). 타입 없는 필드는 아무거나 담김.
#   · truth_key(t::FaultTruth) = ... : 같은 이름 함수를 인자 "타입마다" 다르게 정의(다중 디스패치).
#   · (:fault, t.robot) : 앞의 :fault 는 "심볼(Symbol)" = 가볍고 빠른 이름표. 전체는 튜플.
#   · `!` 로 끝나는 함수(record_ood_truth! 등) = 인자/전역상태를 직접 바꾼다는 관례.
#   · Ref(...) : 값을 감싼 "가변 상자". 전역 상태를 담아 어디서든 [] 로 읽고 씀.
#   · function (env) ... end : 이름 없는 함수(클로저)를 만들어 반환 = "나중에 실행할 액션".
# ============================================================================

# ood_truth.jl
# Ground-truth OOD labels for grounding evaluation (Level 1 of llm_eval.jl).
# See docs/llm_navigator_plan.md.
#
# WHO designs the label / WHEN: a human authors the canonical (NL observation,
# ground-truth label) RULE once, at code-authoring time (before any run), by
# CHOOSING which truth-capturing action wrapper to schedule. The per-instance label
# values (which robot, which zone) are filled AUTOMATICALLY at injection time by the
# generator — no human input per instance, none in real time.
#
# Two channels from one injection (NEVER cross them):
#   • NL observation  -> push_ood! -> the LLM sees it (lossy, ambiguous).
#   • ground-truth label -> OOD_TRUTH_LOG -> the EVALUATOR sees it (LLM never does).
#
# Non-invasive: this file does NOT modify ood_injection.jl. The action wrappers
# WRAP the existing generators (fault_robot!, random_restriction_zone!) and derive
# the truth from known params + post-injection state.
#
# Depends on llm_eval.jl (grounding_prf). The action wrappers additionally depend on
# ConstructionBots' injection functions, so they only run inside the package.

# ---- ground-truth label types -----------------------------------------------------
# Fields left loosely typed (no hard AbstractID dependency) so this stays decoupled
# and standalone-testable; the real RobotID / AbstractID values fit unchanged.

# 모든 정답 라벨의 공통 부모 타입. (OODTruth 를 상속한 구조체들이 각 사건 종류를 표현)
abstract type OODTruth end

# 로봇 고장 정답: robot 이 pos 위치에서 고장남. after = "이 시각 이후로 사용 불가".
"True robot-fault event: `robot` broke down at `pos`, unavailable after `after`."
struct FaultTruth <: OODTruth
    robot            # RobotID / AbstractID in practice
    pos::Vector{Float64}
    after::Float64
end
# after 를 생략하면 0.0 으로 채우는 편의 생성자(같은 이름, 인자 2개짜리 버전).
FaultTruth(robot, pos) = FaultTruth(robot, pos, 0.0)

# 통행금지 구역 정답: zone(이름표) 로 등록된 원형 no-go 구역(center 중심, radius 반지름).
# assembly = 이 구역이 어느 조립체의 staging(대기/정렬 자리)을 막았는지(없으면 nothing = 단순 항법 우회).
"True no-go-zone event: zone registered under key `zone` (center/radius), optionally
blocking staging of `assembly`."
struct ZoneTruth <: OODTruth
    zone::Symbol
    center::Vector{Float64}
    radius::Float64
    assembly         # AbstractID or nothing
end
# assembly 를 생략하면 nothing(= 항법 우회로 충분한 구역)으로 채우는 편의 생성자.
ZoneTruth(zone, center, radius) = ZoneTruth(zone, center, radius, nothing)

# 배터리 사건 정답: robot 의 SoC(State of Charge=충전잔량, 0~1)가 soc_after 로 떨어짐.
# 정답 대응은 "심각도(severity)"에 따라 갈린다 — 아래 REPLACE_SOC_THRESHOLD 설명 참고:
#   · 깊은 방전(soc_after ≤ 임계값): 로봇이 사실상 죽음 -> 하드하게 ReplaceAgent(교체).
#   · 가벼운 열화(soc_after > 임계값): 살려두되 무거운/먼 일을 피하게 하는 소프트 DeprioritizeAgent.
"True battery event: `robot`'s SoC dropped to `soc_after`. The canonical response is
SEVERITY-DEPENDENT (see `REPLACE_SOC_THRESHOLD`): a DEEP discharge (`soc_after ≤ threshold`)
leaves the robot effectively dead — the motion gate freezes it — so the correct response is the
HARD `ReplaceAgent` (same class as a mechanical fault); a mild DEGRADATION (`soc_after > threshold`)
is handled by a TIER-2 soft `DeprioritizeAgent` (route work away, do NOT hard-remove)."
struct BatteryTruth <: OODTruth
    robot            # RobotID / AbstractID in practice
    soc_after::Float64
    after::Float64
end
# after 생략 시 0.0 으로 채우는 편의 생성자.
BatteryTruth(robot, soc_after) = BatteryTruth(robot, soc_after, 0.0)

# 운반팀 교착(deadlock) 정답: 정답 대응은 팀을 기하적으로 다시 짜는 ReformTeam.
# 특정 로봇 하나에 매이지 않는 "팀 단위" 사건이라 필드가 없고, 고정 키 (:reform, :team) 로 채점.
"True transport-team-deadlock event: the canonical response is a geometric ReformTeam.
Team-scoped (no single entity), so it grounds against the sentinel key (:reform, :team)."
struct ReformTruth <: OODTruth
end

# ---- truth log: the evaluator-only channel ----------------------------------------
# Module-level Ref, mirroring RESTRICTION_ZONES / SPARE_POOLS in ood_injection.jl.

# 정답 라벨 저장소(채점기 전용 채널). Ref = 전역 가변 상자. [] 로 안의 벡터를 읽는다.
const OOD_TRUTH_LOG = Ref(Vector{NamedTuple}())
ood_truth_log() = OOD_TRUTH_LOG[]                          # 기록 전체를 그대로 반환
clear_ood_truth_log!() = (empty!(OOD_TRUTH_LOG[]); nothing) # 로그 비우기(다음 실험 전 초기화)

# 주입(injection) 시점에 (nl 관찰, truth 정답) 한 쌍을 로그에 추가. at = 감사용 시각(스텝/누적 완료수).
"Record one (nl, truth) pair at injection. `at` = sim step / closed-count for audit."
function record_ood_truth!(nl::AbstractString, truth::OODTruth; at = nothing)
    push!(OOD_TRUTH_LOG[], (at = at, nl = String(nl), truth = truth))
    return truth
end

# 기록된 정답 라벨만 뽑아 반환(= 실제로 일어난 OOD 목록). [ ... for e in ... ] = 리스트 컴프리헨션.
"All recorded ground-truth labels (the canonical OOD that actually happened)."
ground_truth_labels() = OODTruth[e.truth for e in OOD_TRUTH_LOG[]]

# ---- comparable keys: truth side and emitted-DSL side ------------------------------
# Entity-level grounding: did the LLM name the RIGHT faulted robot / RIGHT zone?
# Strategy choice (ReplaceAgent vs ForbidAgent) is a separate axis, not entity-grounding.

# Battery severity split: a battery event that leaves the robot at/below REPLACE_SOC_THRESHOLD is
# a DEPLETION — the robot is dead (motion-gate frozen), so its canonical response is the HARD
# ReplaceAgent, whose `emitted_key` is (:fault, robot). It therefore grounds against the (:fault, ·)
# key, NOT (:battery, ·). Above the threshold it is a soft DEGRADATION grounding against Deprioritize.
# Scoring against these keys rewards choosing the right SEVERITY CLASS, not merely the right robot.
# 배터리 사건의 소프트↔하드 대응이 갈리는 SoC 경계값(이하이면 하드 Replace). 전역 조정 가능.
const REPLACE_SOC_THRESHOLD = Ref(0.2)
"Set the SoC at/below which a battery event's canonical response flips soft→hard (Replace)."
set_replace_soc_threshold!(x::Real) = (REPLACE_SOC_THRESHOLD[] = Float64(x); nothing)

# truth_key : 정답 라벨을 "비교 가능한 키(튜플)"로 바꾼다 = 채점 때 대응이 맞는지 대조할 열쇠.
truth_key(t::FaultTruth)   = (:fault, t.robot)   # 고장 = (:fault, 그 로봇)
truth_key(t::ZoneTruth)    = (:zone, t.zone)     # 구역 = (:zone, 그 구역 이름표)
# 배터리는 심각도로 키가 갈린다: `조건 ? A : B` 는 삼항연산자(조건이면 A, 아니면 B).
truth_key(t::BatteryTruth) = t.soc_after <= REPLACE_SOC_THRESHOLD[] ?
    (:fault, t.robot) :          # deep discharge -> hard Replace (matches ReplaceAgent/ForbidAgent)
    (:battery, t.robot)          # degradation    -> soft Deprioritize (matches DeprioritizeAgent)
truth_key(::ReformTruth)   = (:reform, :team)    # 팀 교착 = 고정 센티넬 키

# Duck-typed on the spec's type NAME so it works with both the real spec_dsl.jl types
# and standalone mocks with the same fields. Covers the FULL DSL repertoire so
# decision-quality grounding is defined for every OOD kind (fault, zone, battery,
# reform). Returns `nothing` only for specs that carry no groundable entity (ForbidWindow).
#
# NOTE the fault-vs-battery distinction is by SPEC KIND, which encodes the STRATEGY the
# method chose: ForbidAgent/ReplaceAgent == "treat as a hard fault"; DeprioritizeAgent ==
# "treat as a soft degradation". Scoring against the truth key therefore rewards choosing
# the RIGHT severity class, not merely naming the right robot.
# emitted_key : 컨트롤러가 "실제로 내놓은 DSL 지시(c)" 를 truth_key 와 같은 키 형식으로 바꾼다.
# 타입 이름(nameof)만 보고 분기 = 실제 spec_dsl.jl 타입이든 테스트용 목(mock)이든 필드만 같으면 동작(덕타이핑).
function emitted_key(c)
    tn = nameof(typeof(c))                       # c 의 타입 "이름"(심볼)만 뽑아 비교
    if tn === :ReplaceAgent || tn === :ForbidAgent
        return (:fault, c.agent)                 # 교체/재배정 = "하드 고장 취급" 전략
    elseif tn === :ForbidZone
        return (:zone, c.zone)
    elseif tn === :DeprioritizeAgent
        return (:battery, c.agent)               # 우선순위 낮춤 = "소프트 열화 취급" 전략
    elseif tn === :ReformTeam
        return (:reform, :team)
    else
        return nothing                           # 채점 대상 엔티티가 없는 지시(예: ForbidWindow)
    end
end

"""
    grounding_against_truth(emitted, truths) -> NamedTuple

Score the LLM's emitted DSL (a vector of ConstraintSpecs, e.g.
`proposal.constraints`) against the recorded ground-truth OOD labels, via
precision/recall/F1 (`grounding_prf`). `hallucinated` = emitted edits with no
matching true event; `missed` = true events the LLM failed to address.
"""
# 채점 본체: 내놓은 지시들의 키 집합(es) vs 정답들의 키 집합(ts) 을 precision/recall/F1 로 비교.
function grounding_against_truth(emitted, truths)
    es = Set{Any}()
    for c in emitted
        k = emitted_key(c)
        k === nothing || push!(es, k)      # `k === nothing || push!` = k 가 있을 때만 집합에 추가
    end
    ts = Set{Any}(truth_key(t) for t in truths)   # 정답 키 집합
    return grounding_prf(es, ts)                  # 두 집합 비교 -> (precision, recall, f1, ...)
end

# ---- truth-capturing action wrappers (human-facing scheduling API) ----------------
# Use these in place of bare closures when scheduling OOD, so the ground-truth label
# is recorded automatically at injection:
#     schedule_ood!(step, fault_action(target = rid))
#     schedule_ood_at_closed!(n, zone_action(key = :z1))
# (These call ConstructionBots injection fns; only runnable inside the package.)

# 주입 직후 "새로 고장난 로봇"을 찾아냄: 주입 전 목록(before)과 지금 목록의 차집합(setdiff) 첫 원소.
_newly_faulted(before) = begin
    new = setdiff(Set(keys(faulted_robots())), before)
    isempty(new) ? nothing : first(new)
end

# fault_action : "로봇 고장을 일으키고 그 정답(FaultTruth)까지 자동 기록"하는 액션을 만들어 반환.
# 반환값이 함수(env)-> ... 인 이유: 스케줄러가 나중에 원하는 시점에 이 클로저를 호출하기 때문.
"Wrap `fault_robot!` and record a `FaultTruth` for the robot it faults."
function fault_action(; target = nothing, after::Float64 = 0.0, kwargs...)
    return function (env)
        before = Set(keys(faulted_robots()))              # 주입 전 고장 로봇 스냅샷
        nl = fault_robot!(env; target = target, kwargs...) # 실제 고장 주입(자연어 관찰 nl 반환)
        nl === nothing && return nothing                   # 아무도 안 고장났으면 기록 없이 종료
        rid = target === nothing ? _newly_faulted(before) : target  # 대상 미지정 시 새로 고장난 로봇 추론
        rid === nothing || record_ood_truth!(nl,           # rid 가 있으면 정답 라벨 기록
            FaultTruth(rid, get(faulted_robots(), rid, Float64[0.0, 0.0]), after))
        return nl
    end
end

# zone_action : "통행금지 구역을 주입하고 그 정답(ZoneTruth)까지 자동 기록"하는 액션을 만들어 반환.
"Wrap `random_restriction_zone!` and record a `ZoneTruth` for the zone it injects."
function zone_action(; key::Symbol = :zone, assembly = nothing, kwargs...)
    return function (env)
        z, nl = random_restriction_zone!(env; key = key, kwargs...)  # 구역 z 와 관찰 nl 을 함께 받음
        ctr = get_center(z)                                          # 구역 중심 좌표
        record_ood_truth!(nl, ZoneTruth(key, Float64[ctr[1], ctr[2]], Float64(get_radius(z)), assembly))
        return nl
    end
end
