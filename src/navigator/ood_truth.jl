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
# 🔴 2026-08-24 (spec §5.5, Task 6): 정답 대응은 더 이상 심각도로 갈리지 않는다. soft 팔
# (DeprioritizeAgent)이 어휘에서 삭제됐고(Task 5), `canonical_respec(::BatteryTruth)` 는
# deep/mild 를 가리지 않고 `SwapBattery(t.robot)` 하나만 낸다(baselines.jl:96).
# `soc_after` 는 그대로 기록한다 — 서술자·라벨 레인이 읽고, `REPLACE_SOC_THRESHOLD` 는 이제
# reference_policy 의 "정답 vs unscored" 판정에만 쓰인다.
"True battery event: `robot`'s SoC dropped to `soc_after`. The canonical response is NO LONGER
severity-dependent (2026-08-24, spec §5.5): the soft tier-2 arm was deleted from the vocabulary,
so `canonical_respec(::BatteryTruth)` collapses deep discharge and mild degradation into a single
`SwapBattery(t.robot)`. `soc_after` is still recorded (descriptors / label lane read it)."
struct BatteryTruth <: OODTruth
    robot            # RobotID / AbstractID in practice
    soc_after::Float64
    after::Float64
end
# after 생략 시 0.0 으로 채우는 편의 생성자.
BatteryTruth(robot, soc_after) = BatteryTruth(robot, soc_after, 0.0)

# 2026-08-20 (4팔 축소): 여기 있던 `ReformTruth` 를 삭제했다. 운반팀 교착은 **외생 실패 사건이
# 아니었다** — 발화 조건이 `no_progress % REFORM_INTERVAL == 0` 이라는 순수 카운터 modulo 였고,
# 엔진 docstring 이 스스로 "SECOND-ORDER OOD of a spare hand-off" 라고 적었다(= Replace 의 후속
# 결과). 필드가 없는 빈 struct 라 어떤 로봇도 팀도 지목하지 못했다는 것이 그 방증이다.
# 교착 해소는 `maybe_unwedge_nominal!`(respec/ood_injection.jl)이 명목 레인에서 직접 부른다 —
# 결정 epoch 를 만들지 않는다. 사건 종류는 이제 셋이다: fault · battery · zone.

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

"""
    ood_targeted_robots() -> Set

이번 런에서 **이미 OOD 사건의 대상이 된** 로봇들.

왜 필요한가 (2026-09-06 실측). 혼합 케이스(`all3` = fault+battery+zone)에서 두 사건이 **같은
로봇**을 때리고 있었다: tractor all3 32판 중 **16판(50%)**, 거의 전부 `DeliveryBot(1)`.
기전은 두 겹이다 — ① battery 가 대상을 `pick_solo_fault_target`/`pick_hotswap_fault_target`
으로 고르는데(battery.jl `_pick_battery_target`) 그것은 fault 가 쓰는 바로 그 피커다,
② 그 피커들이 `sort(...)[1]` = **id 최소**를 돌려주므로 두 사건이 같은 후보를 본다.
fault 쪽 제외 목록에는 `FAULTED_ROBOTS`·예비만 있고 **"이미 방전된 로봇"이 없었다.**
그러면 all3 의 교란이 사실상 둘이 아니라 하나가 된다 — 2026-09-06 의 종류 비복원추출 수정이
같은 종류의 중복을 없앤 것과 같은 결함이고, 그때 대상 축이 남아 있었다.

🔴 **SoC 나 `FAULTED_ROBOTS` 가 아니라 이 로그를 보는 이유**: 그 둘은 **정책이 바꾼다.**
`SwapBattery` 가 성공해 SoC 가 복구되거나 `Replace` 가 고장 기록을 지우면, 뒤이은 사건의
대상이 **레인마다 달라진다** — canonical/surrogate/router 가 서로 다른 로봇을 고장내는
비교 불가능한 판이 된다. 이 로그는 **주입된 사건**을 적으므로 회복 여부와 무관하고,
`clear_ood_truth_log!()` 로 런마다 초기화된다.

단일 종류 케이스(battery 단독 / fault 단독)에서는 첫 사건이 뽑힐 때 로그가 비어 있어
동작이 **바이트 동일**하다 — 바뀌는 것은 혼합 케이스뿐이다(음성 대조가 이 성질을 잰다).
"""
function ood_targeted_robots()
    hit = Set{Any}()
    for e in OOD_TRUTH_LOG[]
        t = e.truth
        r = try hasproperty(t, :robot) ? t.robot : nothing catch; nothing end
        r === nothing || push!(hit, r)          # ZoneTruth 는 .robot 이 없다 -> 건너뛴다
    end
    return hit
end

# ---- comparable keys: truth side and emitted-DSL side ------------------------------
# Entity-level grounding: did the LLM name the RIGHT faulted robot / RIGHT zone?
# Strategy choice (ReplaceAgent vs ForbidAgent) is a separate axis, not entity-grounding.

# 🔴 2026-08-24 (spec §5.5, Task 6): 여기 있던 "battery severity split" 설명은 폐기됐다.
# `truth_key(::BatteryTruth)` 는 이제 SoC 와 무관하게 (:battery, robot) 하나만 낸다 — 갈라
# 놓을 두 번째 팔이 어휘에 없기 때문이다. 이 상수는 채점 키에서 빠졌고, 남은 소비처는
# reference_policy 의 "정답 vs unscored" 판정 하나다.
# 배터리 사건의 깊은 방전 판정 SoC 경계값. 전역 조정 가능.
# 🔴 2026-08-31 (S1/T3): 0.2 -> 0.1. `tools/monitor/lane_select.jl` 의 라우팅 경계
#    `ROUTING_SEVERE_SOC` 와 **같은 값**이어야 한다. 갈라져 있던 동안 (0.1, 0.2] 구간이
#    LLM 레인으로 가면서 개입 팔을 다 갖는 죽은 밴드였다(합성이 구조적으로 발화 불가).
#    두 값이 갈리는 것은 `test/soc_ladder_is_coherent.jl` (1) 이 막는다.
const REPLACE_SOC_THRESHOLD = Ref(0.1)
"Set the SoC at/below which a battery event's canonical response flips soft→hard (Replace)."
set_replace_soc_threshold!(x::Real) = (REPLACE_SOC_THRESHOLD[] = Float64(x); nothing)

# 로봇이 물리적으로 멈추는 SoC 의 **선언된 기본값** — 🔴 2026-09-01 실측 정정: 이 값을 실제로
# **읽는 프로덕션 소비처는 0개다.** `DEMO_STALL_SOC`(`run_demo.jl`/`render_demo.jl`)·
# `DS_STALL`(`gen_oracle_dataset.jl`)·`STALL_SOC`(`tools/demos.jl`) 는 각자 독립된
# `get(ENV, "NAME", "0.05")` 문자열 리터럴을 든다 — 이 상수에서 유도하지 않는다(할 수도 없다:
# `test/soc_ladder_is_coherent.jl` (4)/(5) 의 `envdefault` 파서는 그 자리가 **벌거벗은 문자열
# 리터럴**이어야만 읽는다 — `string(STALL_SOC_DEFAULT[])` 같은 식으로 바꾸면 정규식이 못
# 찾아 gate 가 죽는다). 그래서 이 `Ref` 는 그 세 리터럴이 서로 같은지 비교하는 **기준점**일
# 뿐이고, "이 값을 쓴다"는 옛 서술은 거짓이었다. `stall < deep`(`REPLACE_SOC_THRESHOLD` 와
# 다른 값이어야 하는 이유)만 게이트가 강제한다 — 같게 두면 deep 구간 전체가 "정지"라 감속
# 구간이 사라지고, `test/battery_ladder_is_deep_only.jl` 단언 2(사다리가 정지 임계를 걸친다 —
# 2026-08-05 "심각도 축이 점 하나" 회귀 방지)를 만족하는 사다리가 **존재하지 않게 된다.**
# ⚠️ `tools/demos.jl` 의 `STALL_SOC` 리터럴은 `soc_ladder_is_coherent.jl` (4)/(5) 어느 쪽에도
# 안 걸린다 — (4)는 run_demo/render_demo 둘만, (5)는 gen_oracle_dataset 의 DS_STALL 만 본다.
# 🔴 2026-09-01 (correction pass, C-3) 정정: 바로 위 문장이 "오늘은 세 리터럴이 우연히 다
# 0.05로 같다"고 적었는데 틀렸다 — 실측: `tools/demos.jl` 안에만 `STALL_SOC` 리터럴이 **둘**
# 있고 값도 서로 **다르다**(`:1059` `demo_energy_stall_replace` 블록은 `"0.02"`, `:1394` OOD
# 블록은 `"0.05"`). 그래서 이름 셋(`DEMO_STALL_SOC`·`DS_STALL`·`STALL_SOC`)이 아니라 리터럴이
# **넷**이고, 값도 전부 같지 않다. `envdefault` 는 `match`(첫 매치)로 읽으므로 같은 이름이
# 한 파일에 두 번 나오면 첫 자리만 본다 — `tools/demos.jl` 에 `STALL_SOC` gate 를 새로 달아도
# 첫 번째 자리(`0.02`)만 잡히고 두 번째 자리(`0.05`)는 이 파서로 주소를 못 딴다.
const STALL_SOC_DEFAULT = Ref(0.05)

# truth_key : 정답 라벨을 "비교 가능한 키(튜플)"로 바꾼다 = 채점 때 대응이 맞는지 대조할 열쇠.
truth_key(t::FaultTruth)   = (:fault, t.robot)   # 고장 = (:fault, 그 로봇)
truth_key(t::ZoneTruth)    = (:zone, t.zone)     # 구역 = (:zone, 그 구역 이름표)
# 🔴 2026-08-24 (spec §5.5, Task 6): severity 삼항연산을 없앴다. soft 대응(DeprioritizeAgent)이
# 어휘에서 사라졌으므로(Task 5) deep/mild 를 가르는 키가 더 이상 **서로 다른 팔**을 가리키지
# 않는다 — 둘 다 SwapBattery 하나로 모인다(baselines.jl:96 의 canonical_respec 가 이미 그렇다).
# SoC 임계값의 남은 소비처는 reference_policy 의 "정답 vs unscored" 하나뿐이다.
truth_key(t::BatteryTruth) = (:battery, t.robot)

# Duck-typed on the spec's type NAME so it works with both the real spec_dsl.jl types
# and standalone mocks with the same fields. Covers the two SCORABLE OOD kinds left after the
# 2026-08-24 three-arm reduction (fault, battery). Returns `nothing` for specs that carry no
# groundable entity (e.g. ForbidWindow) and for zone specs, which no longer ground.
#
# NOTE the fault-vs-battery distinction is by SPEC KIND, which encodes the STRATEGY the
# method chose: ForbidAgent/ReplaceAgent == "treat as a hard fault"; SwapBattery == "treat as a
# recoverable battery event". Scoring against the truth key therefore rewards choosing the RIGHT
# response class, not merely naming the right robot.
# emitted_key : 컨트롤러가 "실제로 내놓은 DSL 지시(c)" 를 truth_key 와 같은 키 형식으로 바꾼다.
# 타입 이름(nameof)만 보고 분기 = 실제 spec_dsl.jl 타입이든 테스트용 목(mock)이든 필드만 같으면 동작(덕타이핑).
function emitted_key(c)
    tn = nameof(typeof(c))                       # c 의 타입 "이름"(심볼)만 뽑아 비교
    if tn === :ReplaceAgent || tn === :ForbidAgent
        return (:fault, c.agent)                 # 교체/재배정 = "하드 고장 취급" 전략
    elseif tn === :SwapBattery
        # 🔴 2026-08-24 (spec §5.5, Task 6): 이 분기가 **없어서** battery grounding 이 구조적으로
        # 0 이었다. canonical_respec(BatteryTruth) 는 이미 deep/mild 를 SwapBattery 하나로
        # 합쳐 놨는데(baselines.jl:96) 채점기만 그 통합을 못 따라가고 있었다. Task 5 로
        # DeprioritizeAgent 가 사라진 뒤로는 battery 가 낼 수 있는 유일한 팔이 이것이다.
        return (:battery, c.agent)               # SwapBattery.agent (spec_dsl.jl)
    elseif tn === :ReformTeam
        return (:reform, :team)
    else
        # 🔴 2026-08-24 (spec §5.5, Task 6): 여기 있던 `ForbidZone` 분기(→ (:zone, c.zone))를
        # 지웠다. 그 분기가 곧 "구역 사건의 정답은 ForbidZone 이다" 라는 **채점 규칙 그 자체**
        # 였는데, zone 은 Task 4 로 결정 레인에서 빠졌다. `truth_key(::ZoneTruth)` 는 남겨 둔다 —
        # 옛 요약 행을 다시 읽을 때 키가 없으면 그 행이 조용히 사라지기 때문이고, zone 을 emit
        # 하는 쪽이 없으므로 채점에서는 자동으로 missed 로 잡힌다.
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
