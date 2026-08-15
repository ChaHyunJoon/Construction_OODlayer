# =============================================================================
# ood_mdp_shim.jl — REPLACES the deleted decpomdp/examples/ood_env_mdp.jl.
#
# The decpomdp/ folder was removed from the checkout, so the generator's original
#   include(".../ood_env.jl"); include(".../ood_env_mdp.jl")
# both died at load. The scan established that the ONLY thing the generator body
# actually references from those files is FOUR functions — everything else it needs
# is CB.* (still present) or defined locally. `ood_env.jl` supplied no symbol the
# generator names directly. So this single shim is a complete replacement.
#
# The four functions are rebuilt on SURVIVING CB code so labels stay byte-compatible
# with the pre-deletion graded dumps:
#   • event_context(env, ev)  — recovers the fired OOD from CB.ood_truth_log()
#                               (ood_truth.jl); ev itself is only the NL string.
#   • valid_actions(ctx)      — legal macro ids per type; mirrors random_macro_respec
#                               repertoires (baselines.jl:193-217).
#   • canonical_action(ctx)   — default macro id; mirrors canonical_respec branching
#                               (baselines.jl:68-102), incl. battery soc split.
#   • action_to_proposal(ctx,a) — macro id -> RespecProposal, via the surviving DSL
#                               constructors (spec_dsl.jl): ReplaceAgent/Deprioritize
#                               Agent/ForbidZone/ReformTeam. NOOP and any invalid
#                               cross-type macro -> nothing (== the NOOP arm).
#
# macro ids (gen_oracle_dataset.jl:73-74): 0 NOOP · 1 Replace · 2 Deprioritize
#                                          3 ForbidZone · 4 ReformTeam
# Replace == ReplaceAgent (gen:474-481; hot-swap is a separate ENACTMENT toggle).
# =============================================================================

# 행동 어휘의 단일 진실원(action_registry.json)을 Julia 쪽에서 파생으로 받는다 (2026-08-16).
# 아래 `valid_actions` 가 이 표를 읽는다 — 그 전에는 kind 별 legal 집합이 이 파일에 리터럴로
# 박혀 있었고, 그게 `ReformTeam(4)` 이 fault 사건에서 라벨될 수 없었던 직접 원인이다.
include(joinpath(@__DIR__, "action_registry.jl"))

# ---- event_context: (type, agent, zone, assembly, soc, after) from the fired OOD --------
# ev is only the natural-language string (replan.jl seam). The structured event lives in the
# OOD truth log, which every injector auto-records at fire time. Match the LAST entry whose
# recorded NL == ev (each fired event appends its own entry; last-match = the just-fired one).
function event_context(env, ev::AbstractString)
    log = try CB.ood_truth_log() catch; Any[] end
    entry = nothing
    for e in Iterators.reverse(log)
        nl = _entry_nl(e)
        if nl == ev
            entry = e; break
        end
    end
    # NL 이 어떤 truth 와도 안 맞으면 그것은 **배경 알람**이다 — 대표적으로 팀 교착
    # (`maybe_emit_reform_ood!`)은 `push_ood!` 만 하고 `record_ood_truth!` 를 하지 않으므로
    # 로그에 항목이 없다.
    #
    # 예전에는 여기서 `last(log)` 를 집었다("newest truth even if NL differs"). 그게 치명적이었다:
    # 방금 터진 다른 사건(예: ZoneTruth)의 종류를 뒤집어써서 팀 교착이 `:zone` 으로 오분류되고,
    # 그러면 생성기 producer 의 `ctx.type === :reform` 분기를 못 타 CASCADE 규칙으로 흘러
    # **NOOP** 이 된다 = 자가복구가 통째로 죽는다.
    # 실측(2026-08-04, oracle/out/rb_core30): 팀 교착 알람 **499회** 발화 → ReformTeam 제안 **0건**,
    # reform 복구 ADMITTED **0건**. 그 판들은 전부 완주 실패했다.
    #
    # 그래서 매칭 실패 시에는 추측하지 말고 **문자열로 분류**한다(그게 정확히 "이 사건이 뭔지
    # 모른다"는 상황에 맞는 처리다). 예약 사건은 record_ood_truth! 가 같은 NL 을 남기므로 항상 매칭된다.
    local ctx
    if entry !== nothing
        t = _entry_truth(entry)
        ctx = t === nothing ? _ctx_from_keywords(ev) : _ctx_from_truth(t, ev)
    else
        ctx = _ctx_from_keywords(ev)          # 매칭 실패 = 배경 알람 → 문자열로 분류
    end
    ctx = _attach_zdiag(env, ctx)             # STEP 1/2: 구역 사건이면 위반 술어를 문맥에 붙인다
    if get(ENV, "DS_SHIM_DEBUG", "0") == "1"
        Base.println(Base.stderr, "[shim] event_context: matched=$(entry!==nothing) type=$(ctx.type) ",
                     "agent=$(ctx.agent) zone=$(ctx.zone) assembly=$(ctx.assembly) soc=$(ctx.soc) log_n=$(length(log))",
                     ctx.zdiag === nothing ? "" : " zdiag=$(ctx.zdiag.verdict) blocked=$(ctx.zdiag.n_blocked)/" *
                                                  "feasible=$(ctx.zdiag.n_restage_feasible) root=$(ctx.zdiag.root_covered) " *
                                                  "teams=$(ctx.zdiag.n_teams_covered)/$(ctx.zdiag.n_teams_forming) " *
                                                  "reloc=$(ctx.zdiag.relocate_feasible)")
    end
    return ctx
end

# ---- STEP 1/2: the VIOLATION PREDICATES, carried on the event context -------------------
# `zone_diagnosis` (src/respec/zone_diagnosis.jl) answers what this zone actually invalidates
# in the scene tree, and derives the cheapest repair that clears it. That verdict IS the
# reference decision rule, so it belongs here — to the ORACLE — and NOT in any prompt or
# feature vector handed to a policy (a policy given the verdict reads the answer instead of
# inferring it; the primitives are what a policy may see).
#
# Only the SCALARS are carried: the ids of `blocked`/`teams` would bloat every ctx, and the one
# id a caller genuinely needs is a `ForbidZone` target, kept as `restage_target`.
#
# `DS_ZONE_DIAG=0` detaches it entirely -> `valid_actions`/`canonical_action` fall back to the
# fixed pre-2026-08-05 behaviour, so old dumps stay reproducible.
# [한] 구역 사건 문맥에 "이 구역이 무엇을 무효화하는가"(zone_diagnosis)를 붙인다. 그 verdict 가
#   곧 기준 결정규칙 = **오라클의 정답**이라, 정책 입력(프롬프트/피처)이 아니라 여기 라벨 쪽에만 있어야 한다.
#   무거운 id 목록은 안 싣고 스칼라만 싣되, ForbidZone 이 지목할 대상 하나(restage_target)는 남긴다.
#   DS_ZONE_DIAG=0 이면 통째로 떼어내 옛 고정 동작으로 되돌아간다(옛 덤프 재현용).
const ZONE_DIAG = Ref(get(ENV, "DS_ZONE_DIAG", "1") == "1")

# ctx 가 옛 방식(zdiag 없음)으로 만들어졌을 수도 있으므로 항상 이 접근자로 읽는다.
_zd(ctx) = try ctx.zdiag catch; nothing end

function _attach_zdiag(env, ctx)
    (ZONE_DIAG[] && ctx.type === :zone && ctx.zone !== nothing) || return Base.merge(ctx, (zdiag = nothing,))
    zd = try
        CB.zone_diagnosis(env, Symbol(ctx.zone))
    catch e
        Base.println(Base.stderr, "[shim] zone_diagnosis failed for :$(ctx.zone): $(e)")
        nothing
    end
    zd === nothing && return Base.merge(ctx, (zdiag = nothing,))
    return Base.merge(ctx, (zdiag = (
        verdict            = zd.verdict,
        n_blocked          = zd.n_blocked,
        n_restage_feasible = zd.n_restage_feasible,
        restage_target     = isempty(zd.feasible) ? nothing : first(zd.feasible),
        root_covered       = zd.root_covered,
        root_total         = zd.root_total,
        n_work_overlap     = zd.n_work_overlap,
        n_teams_forming    = zd.n_teams_forming,
        n_teams_covered    = zd.n_teams_covered,
        relocate_feasible  = zd.relocate_feasible,
        relocate_norm      = zd.relocate_norm),))
end

# truth-log entries are NamedTuples ~ (at, nl, truth); read defensively by field then position.
_entry_nl(e)    = try e.nl    catch; try e[2] catch; "" end end
_entry_truth(e) = try e.truth catch; try e[3] catch; nothing end end

# Dispatch on the truth TYPE NAME (robust to whatever module path CB exposes it under),
# and pull fields with getfield so we never depend on positional constructors.
function _ctx_from_truth(t, ev)
    tn = string(nameof(typeof(t)))
    gf(f, d) = try getfield(t, f) catch; d end
    if tn == "FaultTruth"
        return (type=:fault,   agent=gf(:robot, nothing), zone=nothing, assembly=nothing,
                soc=NaN,               after=Float64(gf(:after, 0.0)), source=String(ev))
    elseif tn == "ZoneTruth"
        return (type=:zone,    agent=nothing, zone=gf(:zone, :zone), assembly=gf(:assembly, nothing),
                soc=NaN,               after=0.0,                     source=String(ev))
    elseif tn == "BatteryTruth"
        return (type=:battery, agent=gf(:robot, nothing), zone=nothing, assembly=nothing,
                soc=Float64(gf(:soc_after, NaN)), after=Float64(gf(:after, 0.0)), source=String(ev))
    elseif tn == "ReformTruth"
        return (type=:reform,  agent=nothing, zone=nothing, assembly=nothing,
                soc=NaN,               after=0.0,                     source=String(ev))
    end
    return _ctx_from_keywords(ev)
end

# Keyword fallback for events with no matching truth entry (e.g. background :reform / wedge alarms).
function _ctx_from_keywords(ev::AbstractString)
    s = lowercase(String(ev))
    ty = (occursin("broken", s) || occursin("faulted", s) || occursin("cannot move", s)) ? :fault :
         (occursin("zone", s)   || occursin("exclusion", s) || occursin("no-go", s))      ? :zone :
         (occursin("battery", s)|| occursin("charge", s)   || occursin("degraded", s))    ? :battery : :reform
    return (type=ty, agent=nothing, zone=nothing, assembly=nothing, soc=NaN, after=0.0, source=String(ev))
end

# ---- valid_actions: legal macro ids per event type (Python reads this as a list) --------
# Derived from the PRE-DELETION dumps (oracle/out/graded/*.jsonl), which are ground truth:
#   fault -> [0,1] ; battery deep(soc<=thr) -> [0,1] ; battery mild(soc>thr) -> [0,2] ;
#   zone -> [0,3] ; reform -> [0,4].
# (Note: this is TIGHTER than random_macro_respec's {0,1,2} — the generator used a soc-split,
# single-intervention mask, and invalid macros collapse to the NOOP arm. See action_to_proposal.)
#
# ---- ZONE ARMS CHANGED 2026-08-03: [0,3] -> [0,7] --------------------------------------
# Macro 3 (ForbidZone -> restage_all_blocked!) has an EMPTY DOMAIN for almost every decision
# point this generator produces. `restage_assembly!` refuses an assembly whose build steps
# have started (`:already_started`), and counting that predicate along a real build gives
# 7 eligible staging circles at closed=0 and **zero** from closed≈46 on — it never refills.
# Every zone decision after the first batch boundary therefore had ForbidZone byte-identical
# to NOOP (oracle/out/zdiag*, seed 203: both arms 238/313, `[RESTAGE-ALL]` never logged),
# which is exactly the measured "zoneblk 36/36 동점, 결정적 n=0". Keeping arm 3 in the action
# set while knowing it duplicates arm 0 would manufacture ties, not measure decisions.
# Macro 7 (RelocateBuild -> translate_whole_build!) has no such precondition (it reads
# `_future_work_discs`, gated on `closed_set` only), so it is the honest zone arm.
# DS_ZONE_ARMS="0,3" restores the old set for reproducing pre-fix dumps.
_zone_arms() = (s = get(ENV, "DS_ZONE_ARMS", "0,7");
                [parse(Int, strip(x)) for x in split(s, ",")])

# ---- ZONE ARMS, PER DECISION POINT (2026-08-05, STEP 2) --------------------------------
# The fixed set above solved the manufactured-tie problem with a blunt instrument: arm 3 was
# dropped GLOBALLY because its domain is *usually* empty. `zone_diagnosis` measures the domain
# at THIS decision point, so the same reasoning can now be applied exactly:
#   * arm 3 (ForbidZone)    is offered only when some blocked assembly can actually be restaged
#     (`n_restage_feasible > 0`) — otherwise `restage_all_blocked!` returns `:none` and the arm
#     is byte-identical to NOOP.
#   * arm 7 (RelocateBuild) is offered only when a clearing shift exists (`relocate_feasible`)
#     — otherwise `translate_whole_build!` returns `:infeasible` and it, too, collapses to NOOP.
# Offering an arm that cannot act does not measure a decision; it manufactures a tie. When
# neither can act the set is `[0]`: the honest statement that this zone has no repair in the
# closed vocabulary (the `:line_stop` case, and exactly where an LLM's PROPOSE_NEW belongs).
# An explicit `DS_ZONE_ARMS` always wins, so pinned reproductions are unaffected.
# [한] 위의 고정 집합은 "arm 3 의 도메인이 대개 비어 있다"는 이유로 그 팔을 **전역으로** 뺀 것이었다.
#   이제 zone_diagnosis 가 **이 결정 시점의** 도메인을 재므로, 같은 논리를 정확히 적용할 수 있다:
#   실제로 옮길 수 있을 때만 3 을, 벗어날 Δ 가 존재할 때만 7 을 제시한다. 둘 다 불가면 [0] —
#   "닫힌 어휘 안에 수복이 없다"는 정직한 진술이고, 그 자리가 곧 LLM 의 PROPOSE_NEW 자리다.
#   행동할 수 없는 팔을 끼워 넣는 것은 결정을 재는 게 아니라 동점을 제조하는 것이다.
_zone_arms_pinned() = haskey(ENV, "DS_ZONE_ARMS")   # 로드시점이 아니라 호출시점에 읽는다(런타임 토글 허용)

function _zone_arms_for(ctx)
    _zone_arms_pinned() && return _zone_arms()   # 명시 지정이 항상 이긴다(옛 덤프 재현 경로)
    zd = _zd(ctx)
    zd === nothing && return _zone_arms()        # 진단이 없으면(플래그 OFF/실패) 옛 고정 집합
    arms = [0]
    zd.n_restage_feasible > 0 && push!(arms, 3)
    zd.relocate_feasible     && push!(arms, 7)
    return arms
end

# ---- 레지스트리 파생으로 전환 (2026-08-16) ---------------------------------------------
# 무엇이 바뀌었나. 위 두 절(2026-08-03 / 08-05)이 고친 것은 **zone 축**이었고, fault·battery 는
# 삭제 이전 덤프에서 베낀 리터럴 그대로였다: fault -> [0,1]. 그런데 이 집합은 `valid_actions` 를
# 지나는 **문지기**이기도 하다(`action_to_proposal`: `a in valid_actions(ctx) || return nothing`).
# 그래서 fault 사건에 매크로 2·4 를 요청하면 조용히 NOOP 팔로 무너졌고, `ReformTeam(4)` 은
# **라벨 격자에 오를 수가 없었다** — 2026-08-15 실측에서 실행 레인은 같은 사건에 ReformTeam 을
# 1182회 집행하는데 배포 라벨셋의 support 는 {0,1,2,7,8} 이었던 이유가 이것이다.
# 이제 kind 별 상한을 `action_registry.json` 에서 받는다(Global Constraint 4). 상태를 아는
# 쪽이 더 **좁히는** 것은 그대로다 — zone 은 결정 시점 기하로, battery 는 아래 SoC 분할로.
#
# 하위호환. `DS_ARMS_LEGACY=1` 이면 2026-08-15 이전의 고정 집합으로 되돌아간다(옛 덤프 재현용).
_legacy_arms() = get(ENV, "DS_ARMS_LEGACY", "0") == "1"

function valid_actions(ctx)
    if ctx.type === :fault
        _legacy_arms() && return [0, 1]
        # {0,1,2,4} (+ DS_COMBO_ARMS=1 이면 5,6). 4 = ReformTeam 이 여기 들어오는 것이
        # 2026-08-16 계획의 1차 목표다 — 실행 레인이 이 사건에서 실제로 쓰는 팔이다.
        return ActionRegistry.kind_valid(:fault)
    elseif ctx.type === :battery
        _legacy_arms() && begin
            thr0 = try Float64(CB.REPLACE_SOC_THRESHOLD[]) catch; 0.2 end
            return (isfinite(ctx.soc) && ctx.soc <= thr0) ? [0, 1, 8] : [0, 2, 8]
        end
        # SoC 분할은 **좁히는** 규칙이라 유지한다(레지스트리 상한 {0,1,2,8} 의 부분집합).
        #   8 = SwapBattery 는 심각도와 무관하게 항상 실행 가능하다 — 방전은 배터리를 갈면 풀리기
        #   때문. 양쪽 칸에 모두 넣어야 "얼마나 방전됐는가"가 팔을 고르는 축이 된다: deep 은
        #   {아무것도 안 함, 본체교체, 배터리교체}, mild 는 {아무것도, 회피, 배터리교체}.
        #   fault 에는 일부러 안 넣는다 — 구동계가 망가진 로봇은 배터리를 갈아도 안 움직인다.
        # DS_BATTERY_SOC_SPLIT=0 이면 분할을 끄고 상한 {0,1,2,8} 을 통째로 제시한다. 그러면
        # "깊은 방전에서도 Deprioritize 가 이기는가" 를 라벨이 직접 답한다(팔 3 -> 4).
        up = ActionRegistry.kind_valid(:battery)
        get(ENV, "DS_BATTERY_SOC_SPLIT", "1") == "1" || return up
        thr = try Float64(CB.REPLACE_SOC_THRESHOLD[]) catch; 0.2 end
        keep = (isfinite(ctx.soc) && ctx.soc <= thr) ? (0, 1, 8) : (0, 2, 8)
        return [a for a in up if a in keep]
    elseif ctx.type === :zone
        # 결정 시점 기하로 좁힌 집합(_zone_arms_for). 레지스트리 상한 {0,3,7} 의 부분집합이다.
        return _zone_arms_for(ctx)
    elseif ctx.type === :reform
        _legacy_arms() && return [0, 4]
        return ActionRegistry.kind_valid(:reform)          # {0,4}
    end
    return [0]
end

# ---- canonical_action: default macro id (mirror of canonical_respec branching) ---------
function canonical_action(ctx)
    if ctx.type === :fault
        return 1                                           # ReplaceAgent
    elseif ctx.type === :zone
        # STEP 2 — the MINIMAL-REPAIR RULE is the canonical zone policy: take the cheapest
        # intervention that clears every violated predicate, and NOOP when nothing is violated.
        # The old rule was "always intervene" (return 7 unconditionally), which is wrong in the
        # direction that costs the most: on a zone that blocks nothing, restraint closed 231
        # nodes (7/8 assemblies) where a whole-build move closed 136 (1/8). `:line_stop` also
        # maps to 0 — there is no repair in this vocabulary, so the honest canonical act is to
        # not pretend otherwise and let the safe fallback own it.
        # [한] 구역의 기준정책 = 최소수복 규칙(위반된 술어를 전부 해소하는 가장 싼 개입, 위반이
        #   없으면 NOOP). 옛 규칙은 "무조건 개입"이었고 그게 가장 비싼 방향의 오답이었다(231 vs 136).
        zd = _zd(ctx)
        if zd !== nothing
            arms = valid_actions(ctx)
            zd.verdict === :forbid_zone    && 3 in arms && return 3
            zd.verdict === :relocate_build && 7 in arms && return 7
            return 0        # :noop / :line_stop / 그 팔이 이 시점에 행동 불가 -> 절제
        end
        # 진단이 없을 때(DS_ZONE_DIAG=0 또는 실패)의 옛 동작: 액션 집합에 있는 개입을 그냥 고른다.
        arms = _zone_arms()
        7 in arms && return 7
        3 in arms && return ctx.assembly === nothing ? 0 : 3   # ForbidZone only if it blocks an assembly
        return 0
    elseif ctx.type === :battery
        thr = try Float64(CB.REPLACE_SOC_THRESHOLD[]) catch; 0.2 end
        # 2026-08-04 SwapBattery 도입으로 기본값이 바뀌었다: 깊은 방전의 단순 규칙은 이제 "본체 교체"가
        # 아니라 "배터리 교체"다. 방전에 귀한 창고 본체를 쓰면, 정작 기계고장이 났을 때 쓸 예비가 없다.
        # (이전: deep -> 1(Replace). 그 시절 라벨은 SwapBattery 가 없던 어휘에서 측정된 것이다.)
        return (isfinite(ctx.soc) && ctx.soc <= thr) ? 8 : 2   # deep -> SwapBattery, mild -> Deprioritize
    elseif ctx.type === :reform
        return 4
    end
    return 0
end

# ---- action_to_proposal: macro id -> RespecProposal | nothing --------------------------
# Uses the surviving DSL constructors. A macro that is invalid for this event type (needs a
# target/zone the ctx does not carry) collapses to `nothing` == the NOOP arm — matching the
# generator's full-5-macro sweep, where invalid rows realize the same run as NOOP.
# ---- COMBINATION ARMS (PLAN_ACTION_GROWTH.md §2 H2, scope (b)) -------------------------
# The engine already accepts MULTIPLE specs -- `RespecProposal.constraints` is a Vector and
# replan.jl iterates `for c in proposal.constraints`. Every macro so far emits exactly ONE
# spec, so the combination axis has never been exercised. These arms exercise it.
#
# OFF BY DEFAULT (`DS_COMBO_ARMS=1` to enable): with the flag unset, ids 5/6 are not in
# valid_actions and therefore collapse to the NOOP arm exactly as before, so every existing
# dump path is byte-identical. The flag only widens what a caller may ASK for.
#
#   5 = [ForbidAgent, ReformTeam]        -- retire the agent WITHOUT spending a spare, then
#                                           reform teams around the loss. The spare-preserving
#                                           alternative to Replace; ForbidAgent is a primitive
#                                           that is not exposed as any macro today.
#   6 = [DeprioritizeAgent, ForbidWindow] -- soft-shed the agent's work AND close a time window
#                                           on the affected node. Two soft levers instead of one.
# 2026-08-16: `const` 에서 **함수**로 바꿨다. 아래 `valid_actions` 는 이제
# `ActionRegistry.is_active` 를 통해 이 플래그를 **호출 시점**에 읽는데, 여기만 include 시점에
# 읽으면 둘이 갈리는 창이 생긴다: 플래그를 로드 뒤에 켜면 `valid_actions(:fault)` 는 5·6 을
# 제시하는데 `action_to_proposal` 의 조합 분기는 안 타고, 그 다음 문지기는 통과하며
# (5 ∈ valid_actions), 어느 `a == ...` 분기에도 안 걸려 `cs === nothing` 으로 **조용히 NOOP** 이
# 된다. 두 곳 다 호출 시점에 읽으면 그 창이 닫힌다.
combo_arms_on() = get(ENV, "DS_COMBO_ARMS", "0") == "1"
const COMBO_IDS  = [5, 6]

function action_to_proposal(ctx, a::Int)
    a == 0 && return nothing
    if combo_arms_on() && a in COMBO_IDS
        return combo_to_proposal(ctx, a)
    end
    a in valid_actions(ctx) || return nothing   # macro invalid for this event type -> NOOP arm
                                                 # (reproduces the dumps: invalid macros == NOOP label)
    cs = nothing
    if a == 1 && ctx.agent !== nothing
        cs = CB.ConstraintSpec[CB.ReplaceAgent(ctx.agent, Float64(ctx.after))]
    elseif a == 2 && ctx.agent !== nothing
        cs = CB.ConstraintSpec[CB.DeprioritizeAgent(ctx.agent, 50.0)]
    elseif a == 3
        # ForbidZone must NAME the assembly it relocates, but `ZoneTruth` does not always carry
        # one — and when it did not, this branch silently produced `nothing` == the NOOP arm.
        # That is the same silent-no-op failure `ZONE_DOMAIN_GATE` exists to expose, one layer
        # up. The diagnosis already computed which blocked assemblies can actually be restaged,
        # so take a target from there rather than dropping the arm.
        # [한] ForbidZone 은 대상 조립체를 지목해야 하는데 ZoneTruth 가 안 실어줄 때가 있었고,
        #   그때 이 분기가 조용히 NOOP 으로 무너졌다(오답이 절제로 위장되는 바로 그 실패).
        #   진단이 "실제로 옮길 수 있는" 집합을 이미 계산했으니 거기서 대상을 고른다.
        zd = _zd(ctx)
        target = ctx.assembly !== nothing ? ctx.assembly :
                 (zd === nothing ? nothing : zd.restage_target)
        target !== nothing && (cs = CB.ConstraintSpec[CB.ForbidZone(target, ctx.zone)])
    elseif a == 4
        cs = CB.ConstraintSpec[CB.ReformTeam()]
    elseif a == 8 && ctx.agent !== nothing
        # SwapBattery(agent) : 같은 본체에 배터리만 현장 교체(창고 본체 소모 없음, swap_battery!).
        cs = CB.ConstraintSpec[CB.SwapBattery(ctx.agent)]
    elseif a == 7 && ctx.zone !== nothing
        # RelocateBuild(zone) : 구역은 그대로 두고 빌드 전체를 Δ 하나로 비켜 옮긴다(translate_whole_build!).
        # ForbidZone(3)과 달리 assembly 를 안 지목하므로 ctx.assembly 가 nothing 이어도 성립한다 —
        # 조립체별 재적치의 전제조건(아직 시작 안 한 조립체)이 빌드 중반에 사라지는 문제를 구조적으로 우회한다.
        cs = CB.ConstraintSpec[CB.RelocateBuild(Symbol(ctx.zone))]
    end
    if get(ENV, "DS_SHIM_DEBUG", "0") == "1"
        Base.println(Base.stderr, "[shim] action_to_proposal: a=$a type=$(ctx.type) assembly=$(ctx.assembly) ",
                     "-> $(cs === nothing ? "nothing (NOOP arm)" : string(cs))")
    end
    cs === nothing && return nothing
    return CB.RespecProposal(cs, "oracle macro $a", String(ctx.source))
end

"조합 팔(5,6) -> 여러 spec 을 담은 RespecProposal. 대상이 없으면 nothing(=NOOP 팔)."
function combo_to_proposal(ctx, a::Int)
    cs = nothing
    if a == 5 && ctx.agent !== nothing
        # 스페어를 쓰지 않고 능력 상실에 대응: 그 로봇을 빼고(ForbidAgent) 팀을 다시 짠다.
        cs = CB.ConstraintSpec[CB.ForbidAgent(ctx.agent, Float64(ctx.after)),
                               CB.ReformTeam()]
    elseif a == 6 && ctx.agent !== nothing
        # 소프트 2단: 일감 가중치를 낮추고, 영향 노드에 시간창을 닫는다.
        # ForbidWindow 는 노드 대상이므로 assembly 가 있을 때만 의미가 있다.
        specs = CB.ConstraintSpec[CB.DeprioritizeAgent(ctx.agent, 50.0)]
        if ctx.assembly !== nothing
            t0 = Float64(ctx.after)
            push!(specs, CB.ForbidWindow(ctx.assembly, t0, t0 + 30.0))
        end
        cs = specs
    end
    cs === nothing && return nothing
    if get(ENV, "DS_SHIM_DEBUG", "0") == "1"
        Base.println(Base.stderr, "[shim] combo arm $a -> $(length(cs)) specs: $(cs)")
    end
    return CB.RespecProposal(cs, "combo arm $a", String(ctx.source))
end
