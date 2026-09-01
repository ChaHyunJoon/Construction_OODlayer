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
# macro ids: **레지스트리가 단일 진실원이다**(core/action_registry.json). 여기 리스트를
# 다시 적지 않는다 — 예전에 적어 둔 "0 NOOP · 1 Replace · 2 Deprioritize · 3 ForbidZone ·
# 4 ReformTeam" 은 2026-08-20(9팔->4팔)과 2026-08-24(4팔->3팔) 재번호로 두 번 거짓이 됐고,
# 그 사이 이 파일을 읽은 사람에게 macro 2 를 두 번 다른 팔로 알려 줬다.
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
    end
    return _ctx_from_keywords(ev)
end

# Keyword fallback for events with no matching truth entry (e.g. background :reform / wedge alarms).
function _ctx_from_keywords(ev::AbstractString)
    s = lowercase(String(ev))
    ty = (occursin("broken", s) || occursin("faulted", s) || occursin("cannot move", s)) ? :fault :
         (occursin("zone", s)   || occursin("exclusion", s) || occursin("no-go", s))      ? :zone :
         (occursin("battery", s)|| occursin("charge", s)   || occursin("degraded", s))    ? :battery : :unknown
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
#
# ---- 🔴 2026-08-24 (3팔 축소): 리터럴 zone 팔 집합을 **삭제**했다 -------------------------
# 기본값은 `"0,2"` 였고 그 `2` 는 RelocateBuild 였다. 그 팔이 어휘에서 사라지고 SwapBattery 가
# 3 -> 2 로 재번호되면서, 이 리터럴을 그대로 두면 **배터리 교체가 zone 팔로 조용히 밀려
# 들어간다** — 이 파일 어디에도 그것을 잡는 테스트가 없다. DS_ZONE_ARMS 환경변수 경로도 같은
# 이유로 없앴다: 임의의 정수를 어휘 밖에서 주입하는 문이었다.
# 이제 zone 팔은 **레지스트리 파생**이다. `kinds` 에 "zone" 을 가진 팔이 하나도 없으므로 오늘
# 이 값은 `[0]` = "닫힌 어휘 안에 이 구역의 수복이 없다" 는 정직한 진술이다(위 STEP 2 문단이
# `:line_stop` 이라고 부르던 바로 그 경우). 어휘에 zone 팔이 다시 생기면 자동으로 따라온다.
# ⚠️ zone **분기 구조 자체**의 제거는 Task 4 의 몫이다 — 여기서는 id 경로만 걷어냈다.
_zone_arms() = sort(unique(vcat(0, ActionRegistry.kind_valid(:zone))))

# ---- ZONE ARMS, PER DECISION POINT (2026-08-05, STEP 2) — 🔴 2026-08-24 삭제 -------------
# 여기에는 `_zone_arms_pinned` / `_zone_arms_for` 가 있었다. 결정 시점 기하(`zone_diagnosis`)로
# zone 팔 집합을 좁히는 코드였고, 그 본체는 `zd.relocate_feasible && push!(arms, 2)` — 즉
# **매크로 id 2 를 직접 push** 하는 경로였다. 3팔 축소로 id 2 는 SwapBattery 가 됐으므로 그대로
# 두면 배터리 교체가 zone 팔 집합에 들어간다. 이 경로는 레지스트리 상한을 안 거치므로 어휘를
# 줄이는 것만으로는 막히지 않는다 — 그래서 지웠다.
# zone 팔은 이제 `_zone_arms()`(레지스트리 파생) 하나뿐이고 오늘 그 값은 `[0]` 이다.

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

"""
    soc_split_enabled() -> Bool

`DS_BATTERY_SOC_SPLIT` 손잡이의 **단일 판독점**. 아래 `valid_actions` 의 battery 분기와
`gen_oracle_dataset.jl` 의 `soc_split` 도장이 **둘 다 이 함수를 부른다**.

왜 함수인가 (2026-08-25, Task 8 / R-50): 이 손잡이는 라벨의 의미를 갈라 놓는데 산출물에
흔적을 안 남겼다 — `SPLIT=0` 라벨과 `SPLIT=1` 라벨은 `vocab`·`objective_hash`·`hot_swap`
이 전부 같다(실측). 유일한 구분자가 행의 `valid_mask` 였고 그걸 게이트하는 소비처는 없다.
그래서 도장을 심었는데, 도장이 기본값 문자열 `"1"` 을 **두 번째로 복사**해서 읽으면 한쪽만
고쳤을 때 도장이 조용히 거짓말한다. 판독점을 하나로 묶어 그 경로를 없앤다.

🔴 `DS_ARMS_LEGACY=1` 이 왜 여기 들어오나 (2026-08-25, Task 8b / M3): 아래 `valid_actions` 의
battery 분기는 legacy 일 때 **`soc_split_enabled()` 를 보기도 전에** 되돌아가고, 그 legacy 경로는
`ctx.soc <= thr0` 로 **언제나 SoC 로 메뉴를 가른다**. 그러니 `DS_ARMS_LEGACY=1 DS_BATTERY_SOC_SPLIT=0`
으로 돌리면 메뉴는 갈렸는데 도장은 `false` 를 찍는다 = 도장이 거짓말한다. 8b 는 이 런에서 그
플래그를 쓰지 않지만, **거짓말할 수 있는 도장은 그 자체가 결함**이므로 판독점에서 막는다.
"""
# 2026-08-25: 기본값 문자열 `"1"` 의 사본을 없앤다 — 판독점은 `ActionRegistry.soc_split_enabled`.
soc_split_enabled() = _legacy_arms() || ActionRegistry.soc_split_enabled()

function valid_actions(ctx)
    if ctx.type === :fault
        _legacy_arms() && return [0, 1]
        # {0,1,2,4} (+ DS_COMBO_ARMS=1 이면 5,6). 4 = ReformTeam 이 여기 들어오는 것이
        # 2026-08-16 계획의 1차 목표다 — 실행 레인이 이 사건에서 실제로 쓰는 팔이다.
        return ActionRegistry.kind_valid(:fault)
    elseif ctx.type === :battery
        # navigator.jl 은 이 파일을 include 하는 두 자리(gen_oracle_dataset.jl:58-60,
        # test/smdp_stamp_smoke.jl:10-179) 모두에서 이 함수가 처음 불리기 전에 이미 로드된다
        # — 심볼이 없으면 이제 UndefVarError 로 죽는다(2026-08-31 폴백 제거).
        _legacy_arms() && begin
            thr0 = Float64(CB.REPLACE_SOC_THRESHOLD[])
            return (isfinite(ctx.soc) && ctx.soc <= thr0) ? [0, 1, 2] : [0, 2]
        end
        # SoC 분할은 **좁히는** 규칙이라 유지한다(레지스트리 상한 `kind_valid(:battery)` 의
        # 부분집합. 그 상한을 여기 숫자로 적지 않는다 — 예전 이 자리의 `{0,1,2,8}` 은 9팔
        # 시절의 값이라 두 번의 재번호로 거짓이 됐다).
        #   SwapBattery 는 심각도와 무관하게 항상 실행 가능하다 — 방전은 배터리를 갈면 풀리기
        #   때문. 양쪽 칸에 모두 넣어야 "얼마나 방전됐는가"가 팔을 고르는 축이 된다: deep 은
        #   {아무것도 안 함, 본체교체, 배터리교체}, mild 는 {아무것도 안 함, 배터리교체}.
        #   (mild 의 세 번째 칸이던 Deprioritize/회피는 2026-08-20 축소로 어휘에서 빠졌다.)
        #   fault 에는 일부러 안 넣는다 — 구동계가 망가진 로봇은 배터리를 갈아도 안 움직인다.
        # 🔴 DS_BATTERY_SOC_SPLIT=0 이면 분할을 끄고 상한을 통째로 제시한다. 3팔 어휘에서 그
        # 차이는 **mild(soc>thr) 칸에서 Replace(1) 가 메뉴에 남느냐**다: SPLIT=1 이면 빠지고,
        # 그러면 라벨 격자가 `macro=1` 행을 만들어도 `action_to_proposal` 문지기가 걸러
        # **실제로는 NOOP 을 돈 행**이 `macro=1` 로 기록된다(에러 없이). 그래서 이 손잡이는
        # 라벨의 의미를 가르고, 행에 `soc_split` 도장으로 남는다(`soc_split_enabled`).
        # (예전 이 자리의 "깊은 방전에서도 Deprioritize 가 이기는가 / 팔 3 -> 4" 는 그 팔이
        #  어휘에 있던 시절의 서술이다.)
        # 🔴 2026-08-25: 여기 있던 `keep = ... ? (0,1,2) : (0,2)` 리터럴을 지웠다. 그 튜플은
        # 재번호 때마다 조용히 거짓이 되는 종류였고(주석이 그 위험을 직접 적고 있었다), 무엇보다
        # **실행 레인(`policy.jl valid_macros`)에는 이 분할이 아예 없어서** 두 레인의 행동공간이
        # 갈려 있었다. 분할 규칙을 어휘 단일 진실원으로 올리고 두 레인이 같은 함수를 부른다.
        # 게이트: `test/battery_menu_lanes_agree.jl`.
        # navigator.jl 로드 보장은 위 legacy 분기 주석 참조 — 심볼이 없으면 UndefVarError.
        thr = Float64(CB.REPLACE_SOC_THRESHOLD[])
        return ActionRegistry.battery_arms(ctx.soc, thr, soc_split_enabled())
    elseif ctx.type === :zone
        # 2026-08-24: 레지스트리에 zone 팔이 없다 -> `[0]`. 결정 시점 기하로 좁히던 경로
        # (_zone_arms_for)는 매크로 id 2 를 직접 push 했으므로 재번호와 함께 삭제했다.
        return _zone_arms()
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
        # 🔴 2026-08-24 (3팔 축소): 여기 있던 두 줄(`... && 2 in arms && return 2`)은 매크로
        # id 2 를 RelocateBuild 로 읽던 코드다. 재번호 뒤 그 id 는 SwapBattery 이므로 그대로
        # 두면 **구역 사건의 기준행동이 배터리 교체**가 된다. 어휘에 zone 개입 팔이 없는 이상
        # 정직한 기준행동은 절제(NOOP) 하나뿐이다 — 위 STEP 2 문단의 `:line_stop` 경우.
        return 0
    elseif ctx.type === :battery
        # 2026-08-04 SwapBattery 도입으로 기본값이 바뀌었다: 깊은 방전의 단순 규칙은 이제 "본체 교체"가
        # 아니라 "배터리 교체"다. 방전에 귀한 창고 본체를 쓰면, 정작 기계고장이 났을 때 쓸 예비가 없다.
        # (이전: deep -> 1(Replace). 그 시절 라벨은 SwapBattery 가 없던 어휘에서 측정된 것이다.)
        # 2026-08-20 (4팔 축소): mild 의 기준정책이던 Deprioritize 가 어휘에서 빠졌다. 남은
        # 개입은 SwapBattery 하나이고, 그것은 심각도와 무관하게 항상 실행 가능하다(방전은
        # 배터리를 갈면 풀린다). 그래서 기준정책이 SoC 에 더 이상 민감하지 않다 — deep/mild
        # 둘 다 같은 팔. `thr` 은 valid_actions 의 SoC 분할이 계속 쓰므로 거기서만 갈린다.
        # 🔴 2026-08-24 재번호: 그 팔의 id 가 3 -> 2 다. 이 리터럴을 안 고치면 3 이 레지스트리
        # 밖 id 가 되어 `action_to_proposal` 이 `nothing` 을 내고 **battery 기준행동이 조용히
        # NOOP 으로 무너진다**(에러 없이 성능으로만 샌다).
        return 2   # 2 = SwapBattery (구 3, 그 앞은 8)
    end
    return 0
end

# ---- action_to_proposal: macro id -> RespecProposal | nothing --------------------------
# Uses the surviving DSL constructors. A macro that is invalid for this event type (needs a
# target/zone the ctx does not carry) collapses to `nothing` == the NOOP arm — matching the
# generator's full-5-macro sweep, where invalid rows realize the same run as NOOP.
function action_to_proposal(ctx, a::Int)
    a == 0 && return nothing
    a in valid_actions(ctx) || return nothing   # macro invalid for this event type -> NOOP arm
                                                 # (reproduces the dumps: invalid macros == NOOP label)
    cs = nothing
    if a == 1 && ctx.agent !== nothing
        cs = CB.ConstraintSpec[CB.ReplaceAgent(ctx.agent, Float64(ctx.after))]
    elseif a == 2 && ctx.agent !== nothing
        # SwapBattery(agent) : 같은 본체에 배터리만 현장 교체(창고 본체 소모 없음, swap_battery!).
        # 🔴 2026-08-24: id 3 -> 2. 이 자리에 있던 `a == 2 && ctx.zone !== nothing` ->
        # `CB.RelocateBuild(...)` 분기는 **삭제**했다 — 재번호 뒤 두 분기가 같은 id 를 다투게
        # 되고, 앞선 zone 분기가 이겨서 배터리 사건이 구역 이동 제안을 받게 된다.
        # (`CB.RelocateBuild` 타입 자체는 Julia 쪽에 남아 있다 — 어휘에서만 빠졌다.)
        cs = CB.ConstraintSpec[CB.SwapBattery(ctx.agent)]
    end
    if get(ENV, "DS_SHIM_DEBUG", "0") == "1"
        Base.println(Base.stderr, "[shim] action_to_proposal: a=$a type=$(ctx.type) assembly=$(ctx.assembly) ",
                     "-> $(cs === nothing ? "nothing (NOOP arm)" : string(cs))")
    end
    cs === nothing && return nothing
    return CB.RespecProposal(cs, "oracle macro $a", String(ctx.source))
end

