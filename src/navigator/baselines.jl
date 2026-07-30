# ============================================================================
#  [한국어 안내] 이 파일 = "LLM 이 아닌 대조군(baseline) 대응기들" B0~B5 모음
#  ---------------------------------------------------------------------------
#  프로젝트 역할:
#   · OOD(예상 밖 사건)가 터지면 어떤 "대응책(RespecProposal = 재명세 제안)"을 내야 한다.
#     LLM 이 정말 값어치가 있는지 증명하려면, LLM 없이도 잘하는/못하는 여러 대조군과
#     "똑같은 조건"에서 겨뤄봐야 한다 — 이 파일이 그 대조군들을 정의한다.
#   · 중요: 모든 대응기는 downstream(검증->재해결->채점)이 전부 동일하다.
#     오직 "제안을 만들어내는 생산자(producer)"만 다르다. 공정성의 핵심 = "입력을 무엇으로 받나".
#
#  대조군 요약(무엇을 입력으로 받는가로 난이도가 갈림):
#     B0 no_adapt_respec  : 아무것도 안 함(바닥선). 계획 차원 대응 0, 모션 스택만.
#     B1 canonical_respec : "구조화된 정답(truth)"을 그대로 받아 규칙표로 대응(= 오라클 탐지기). 상한선.
#     B2 b2_respec        : 자연어(NL)를 "직접" 정규식으로 파싱해서 대응. 일부러 취약하게.
#     B3 oracle_respec    : B1 의 대안 enactment(MILP 재배정). 진짜 오라클 = per-instance {B1,B3} 중 나은 것.
#     B4 reactive_only    : 매크로 없는 순수 반응 제어(제안 차원은 B0 와 동일).
#     B5 random_macro     : 올바른 grounding 위에서 DSL 종류를 무작위로 고름(결정의 가치를 격리).
#     LLM llm_respec      : 기존 llm_bridge(비교 대상 본체).
#
#  문법 참고:
#   · f(x) = ...            : 한 줄짜리 함수 정의(축약형).
#   · canonical_respec(t::ZoneTruth) : 인자 타입마다 다른 메서드(다중 디스패치).
#   · ConstraintSpec[ ... ] : ConstraintSpec 원소들의 "타입 지정 배열" 리터럴.
#   · `조건 ? A : B`         : 삼항연산자(조건이면 A, 아니면 B).
#   · r"..."                : 정규식(Regex) 리터럴. 뒤의 i = 대소문자 무시 플래그.
#   · `!` 접미사             : 없음(이 파일은 순수 생성자 위주). args... = 가변인자.
# ============================================================================

# baselines.jl
# Non-LLM OOD-response baselines B0–B2 for the LLM ablation. See
# docs/llm_navigator_plan.md.
#
# All baselines share the SAME downstream as the LLM (verifier -> maybe_respecify!
# -> solve -> RunMetrics); only the PRODUCER of the RespecProposal differs. The
# fairness knob is what each producer receives as INPUT:
#
#   B0  no_adapt_respec(_)        -> nothing          (no planning-level response;
#                                                       motion stack only)
#   B1  canonical_respec(truth)   -> RespecProposal   (GIVEN the structured OOD =
#                                                       oracle detector; rule map)
#   B2  b2_respec(nl)             -> RespecProposal?  (must PARSE the NL observation
#                                                       with a brittle hand-coded parser)
#   LLM llm_respec(nl)            -> RespecProposal?  (existing llm_bridge)
#
# B1 isolates RESPONSE quality (the LLM ~never beats it on outcome — honest ceiling).
# B2 is the REAL competitor: it must translate the observation itself, and its parser
# is DELIBERATELY brittle (fixed-template regex). On NL/novel phrasings it fails and
# fires nothing — which is exactly where the LLM earns its keep.
#
# canonical_respec / b2_respec construct real spec_dsl.jl types (RespecProposal,
# ReplaceAgent, ForbidZone) so they run inside the package; parse_observation is
# decoupled (returns ood_truth.jl types) and standalone-testable.

# ============================================================================
# B0 — no-adapt (floor). Producer that never acts; pair with RESPEC_ENABLED=false.
# ============================================================================
# B0: 무슨 입력이 오든(args... = 인자 아무거나) 항상 nothing = "대응 안 함". 성능 바닥선.
no_adapt_respec(args...) = nothing

# ============================================================================
# B1 — rule-based respec from the STRUCTURED OOD (oracle detector).
# The canonical correct response. This is ALSO the grounding ground-truth: the
# LLM is scored against exactly these edits.
# ============================================================================

# B1(고장): 정답 truth 를 받아 "가장 가까운 예비 로봇으로 1:1 교체(ReplaceAgent)" 제안을 만든다.
"Canonical RespecProposal for a structured OOD truth (the B1 rule map)."
canonical_respec(t::FaultTruth) =
    RespecProposal(ConstraintSpec[ReplaceAgent(t.robot, t.after)],
                   "B1: robot fault -> nearest-spare 1:1 hand-off", "rule")

# B1(구역): assembly 유무로 갈린다 — 없으면 항법 우회(DSL 불필요), 있으면 그 조립체를 다른 곳으로.
function canonical_respec(t::ZoneTruth)
    if t.assembly === nothing
        # 항법용 no-go 구역: staging 을 안 막으므로 모션 스택이 알아서 우회 -> 계획 차원 DSL 은 "빈 것"이 정답.
        # nav no-go zone kept clear of staging (random_restriction_zone! guarantees
        # this) -> motion stack detours; NO planning-level DSL is the correct response.
        return RespecProposal(ConstraintSpec[], "B1: nav zone -> motion-stack detour (no DSL)", "rule")
    else
        # 구역이 staging 자리를 막음 -> 그 조립체를 옮기라는 ForbidZone 지시(공간 재배치).
        # zone blocks a staging area -> relocate that assembly.
        return RespecProposal(ConstraintSpec[ForbidZone(t.assembly, t.zone)],
                              "B1: staging blocked -> restage assembly", "rule")
    end
end

# B1(배터리): 심각도로 갈림 — 깊은 방전(SoC ≤ 임계값)은 하드 교체(ReplaceAgent),
# 가벼운 열화는 소프트 우선순위 낮춤(DeprioritizeAgent, 살려두고 일만 덜어줌).
"Canonical response to a battery event, SEVERITY-DEPENDENT (matches truth_key(::BatteryTruth)):
a deep discharge (SoC ≤ REPLACE_SOC_THRESHOLD) is treated as a hard fault -> ReplaceAgent; a mild
degradation stays a Tier-2 soft DeprioritizeAgent (route work away, keep usable)."
canonical_respec(t::BatteryTruth) =
    t.soc_after <= REPLACE_SOC_THRESHOLD[] ?
        RespecProposal(ConstraintSpec[ReplaceAgent(t.robot, t.after)],
                       "B1: battery flat -> hard replace (spare hand-off)", "rule") :
        RespecProposal(ConstraintSpec[DeprioritizeAgent(t.robot, 50.0)],
                       "B1: battery degraded -> soft deprioritize (feasible-preserving)", "rule")

# B1(팀 교착): 정답은 팀을 기하적으로 다시 짜는 ReformTeam. (::ReformTruth = 값은 안 쓰고 타입만 매칭)
"Canonical response to a transport-team deadlock: geometric re-establishment."
canonical_respec(::ReformTruth) =
    RespecProposal(ConstraintSpec[ReformTeam()], "B1: team deadlock -> reform", "rule")

# B1 별칭: 어떤 종류의 정답 truth 든 받아 위의 canonical_respec 로 넘겨줌(추상타입 OODTruth 로 전부 수용).
"B1 alias: produce the canonical proposal from a structured truth."
rule_based_respec(t::OODTruth) = canonical_respec(t)

# ============================================================================
# B2 — hand-coded NL parser (DELIBERATELY brittle) + canonical response.
# ============================================================================
# Regex anchored to the EXACT templates the generators emit (fault_robot! /
# restriction_zone_event). Any paraphrase, reordering, or novel phrasing falls
# through to `nothing` — the brittleness that makes B2 lose to the LLM on NL input.

# B2 가 파싱하는 정규식 2개. 생성기가 뱉는 "정확한 문장 틀"에만 맞음(괄호 안 = 캡처그룹: 로봇번호/좌표/반지름).
# 조금만 표현이 바뀌어도 매칭 실패 = B2 의 의도된 취약성. \d+ = 숫자, \s* = 공백들, [-\d.]+ = 부호/숫자/점.
const _FAULT_RE = r"Robot\s+R(\d+)\s+has broken down at\s+\(\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\)"i
const _ZONE_RE  = r"exclusion zone.*?centered near\s+\(\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\)\s+with radius\s+([-\d.]+)"i

"""
    parse_observation(nl; mkrobot=identity) -> Union{OODTruth,Nothing}

B2's hand-coded parser: regex-extract a structured OOD from the NL observation.
`mkrobot` maps the parsed integer id to the domain id type (pass `RobotID` inside
the package; default `identity` for tests). Returns `nothing` on any phrasing the
fixed templates don't match — B2 then fires no response (its core limitation).

Note: the NL carries geometry but NOT the registered zone key or the affected
assembly, so a parsed zone defaults to a nav-detour (`zone=:parsed`,
`assembly=nothing`) -> canonical no-op. Recovering key/assembly for a relocation
scenario needs geometric matching against RESTRICTION_ZONES (left to a caller hook;
itself brittle glue the LLM can sidestep via `open_zone_descriptors`).
"""
# B2 의 손코딩 파서: 자연어 nl 에서 정규식으로 구조화된 OOD 를 뽑아낸다.
# mkrobot = 파싱한 정수 id 를 도메인 id 타입으로 바꾸는 함수(기본 identity = 그대로; 패키지 안에선 RobotID 전달).
function parse_observation(nl::AbstractString; mkrobot = identity)
    m = match(_FAULT_RE, nl)                     # 먼저 "고장" 틀과 대조
    if m !== nothing
        id = parse(Int, m.captures[1])           # 첫 캡처그룹 = 로봇 번호
        x = parse(Float64, m.captures[2]); y = parse(Float64, m.captures[3])  # 좌표
        return FaultTruth(mkrobot(id), Float64[x, y], 0.0)
    end
    m = match(_ZONE_RE, nl)                      # 아니면 "구역" 틀과 대조
    if m !== nothing
        cx = parse(Float64, m.captures[1]); cy = parse(Float64, m.captures[2])
        r  = parse(Float64, m.captures[3])
        # nl 엔 구역 키/막힌 조립체 정보가 없어 :parsed / assembly=nothing 으로 둠 -> 항법 우회(no-op)로 귀결.
        return ZoneTruth(:parsed, Float64[cx, cy], r, nothing)
    end
    return nothing   # unrecognized phrasing -> B2 cannot respond  # 어느 틀에도 안 맞으면 대응 불가
end

"""
    b2_respec(nl; mkrobot=identity) -> Union{RespecProposal,Nothing}

B2 producer: parse the NL observation, then apply the canonical rule. `nothing`
(no response) when the parser fails — the failure mode that separates B2 from the LLM.
"""
# B2 생산자: nl 을 직접 파싱(parse_observation) -> 성공하면 B1 규칙(canonical_respec) 적용, 실패하면 nothing.
function b2_respec(nl::AbstractString; mkrobot = identity)
    t = parse_observation(nl; mkrobot = mkrobot)
    t === nothing && return nothing          # 파싱 실패 = 무응답(B2 와 LLM 을 가르는 실패 모드)
    return canonical_respec(t)
end

# ============================================================================
# B3 — oracle: optimal re-solve enactment (alternative to B1's spare hand-off).
# Same structured input as B1; emits ForbidAgent (MILP reassignment) for faults.
# The TRUE oracle outcome = the BETTER of {B1, B3} per instance (see compare.jl):
# MILP reassignment carries the double-booking issue, so spare hand-off may dominate
# it on this system — the oracle must not be pinned to one enactment.
# ============================================================================
# B3(고장): 예비 교체 대신 MILP 로 최적 "재배정(ForbidAgent)". zone/battery/reform 은 B1 정답이 이미 최적이라 재사용.
oracle_respec(t::FaultTruth) =
    RespecProposal(ConstraintSpec[ForbidAgent(t.robot, t.after)],
                   "B3: robot fault -> optimal MILP reassignment", "oracle")
oracle_respec(t::ZoneTruth) = canonical_respec(t)   # optimal restage == canonical restage
oracle_respec(t::BatteryTruth) = canonical_respec(t)   # severity-aware canonical is the optimal enactment
oracle_respec(::ReformTruth)   = RespecProposal(ConstraintSpec[ReformTeam()], "B3: reform", "oracle")

# ============================================================================
# B5 — random-macro (sanity floor for the LEARNED macro head). Given CORRECT
# grounding (the truth's entity), it picks a random DSL spec KIND from the macro
# repertoire — including strategy MISTAKES (hard-remove a merely-degraded robot) and
# a no-op. It isolates the value of the DECISION: if a random choice over the same
# repertoire already does well, the learned policy has earned little. Reproducible via
# `rng`. Vary `rng`/seed per call so it is not stuck on one arm.
# ============================================================================
# 후보 xs 중 하나를 rng 로 무작위 선택(재현성 위해 rng 를 매 호출 다르게 주는 게 좋음).
_random_choice(rng, xs) = xs[Int(floor(rand(rng) * length(xs))) + 1]

# B5(고장): 올바른 대상(t.robot) 위에서 DSL 종류만 무작위로 고름 — 일부러 "전략 실수"(교체/재배정/우선순위낮춤)도 섞음.
function random_macro_respec(t::FaultTruth; rng = Random.GLOBAL_RNG)
    cands = ConstraintSpec[ReplaceAgent(t.robot, t.after),
                           ForbidAgent(t.robot, t.after),
                           DeprioritizeAgent(t.robot, 50.0)]
    c = _random_choice(rng, cands)
    return RespecProposal(ConstraintSpec[c], "B5: random macro on faulted robot", "random")
end
# B5(배터리): 마찬가지로 무작위 — 열화 로봇을 하드 제거하는 실수까지 포함(결정의 가치를 격리하려는 의도).
function random_macro_respec(t::BatteryTruth; rng = Random.GLOBAL_RNG)
    cands = ConstraintSpec[DeprioritizeAgent(t.robot, 50.0),
                           ReplaceAgent(t.robot, t.after),
                           ForbidAgent(t.robot, t.after)]
    c = _random_choice(rng, cands)
    return RespecProposal(ConstraintSpec[c], "B5: random macro on degraded robot", "random")
end
# B5(구역): 항법 구역(assembly=nothing)이면 무응답, staging 막힘이면 50% 확률로 ForbidZone / 50% 무응답.
function random_macro_respec(t::ZoneTruth; rng = Random.GLOBAL_RNG)
    t.assembly === nothing && return nothing
    return rand(rng) < 0.5 ?
        RespecProposal(ConstraintSpec[ForbidZone(t.assembly, t.zone)], "B5: random (zone)", "random") :
        nothing
end
# B5(팀 교착): 50% 확률로 ReformTeam, 아니면 무응답.
random_macro_respec(::ReformTruth; rng = Random.GLOBAL_RNG) =
    rand(rng) < 0.5 ? RespecProposal(ConstraintSpec[ReformTeam()], "B5: random (reform)", "random") : nothing

# ============================================================================
# B4 — reactive-only (the floor MARL degrades to WITHOUT the macro head). At the
# planning/proposal level B4 emits NOTHING (== B0): its only response to OOD is the
# execution-layer motion stack (throttle / RVO / TangentBug detour). B4 exists to
# ISOLATE the value of the DSL macro action space — the gap (MARL − B4) is exactly
# what the structural head buys over pure reactive control. As a per-event PRODUCER it
# is identical to B0; it becomes distinct only in a full ROLLOUT (see controller.jl:
# ReactiveOnlyController, which additionally drives a throttle heuristic).
# ============================================================================
# B4: 제안 차원에선 항상 무응답(= B0 와 동일). 차이는 전체 rollout 에서만 드러남(모션 스택만으로 반응).
reactive_only_respec(args...) = nothing

# ---- grounding reference = the canonical correct response's keys --------------
# Supersedes entity-level `truth_key` for nav-only zones (whose correct response is
# NO DSL): a method that correctly emits nothing scores grounded; one that emits a
# spurious ForbidZone is penalized as a false positive (over-reaction).
# 내놓은 지시들(emitted)을 채점용 키 집합으로 변환(nothing 키는 제외).
function _emitted_keyset(emitted)
    s = Set{Any}()
    for c in emitted
        k = emitted_key(c)
        k === nothing || push!(s, k)
    end
    return s
end

# 정답 truth 들의 "정답 대응(canonical_respec)"이 내놓을 키 집합. `for t in truths, c in ...` = 이중 루프.
# 핵심: 항법 구역처럼 "정답이 빈 대응"인 경우, 아무 것도 안 내야 grounded — 헛 ForbidZone 을 내면 오탐(과잉대응)으로 감점.
function canonical_keys(truths)
    ks = Set{Any}()
    for t in truths, c in canonical_respec(t).constraints
        k = emitted_key(c)
        k === nothing || push!(ks, k)
    end
    return ks
end

# 내놓은 DSL vs "정답 대응"의 키를 precision/recall/F1 로 채점(no-op 정답도 올바르게 다룸).
"Grounding PRF of emitted DSL vs the CANONICAL correct response (handles no-op truths)."
grounding_vs_canonical(emitted, truths) = grounding_prf(_emitted_keyset(emitted), canonical_keys(truths))
