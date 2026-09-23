# =============================================================================
# zone_diagnosis.jl -- the VIOLATION PREDICATES for a spatial no-go zone.
# =============================================================================
#
# WHY THIS FILE EXISTS
# --------------------
# The re-spec action space is over the SCENE TREE (which staging area / build position sits
# where), while a `ForbidZone` is a constraint over NAVIGATION space (where a robot may
# travel). The two only couple through the scene tree's IMAGE in the workspace: staging
# circles, root deposit goals, and the work discs the unfinished schedule still has to reach.
#
# So a zone only forces a scene-tree action when it INVALIDATES one of those. When it does
# not, the reactive motion stack (TangentBug -> potential field -> RVO) simply routes around
# it and `NOOP` is the genuinely correct answer -- not a degenerate one. This file computes
# which of them a given zone invalidates, in ONE place, so that:
#
#   * the ORACLE can label a zone decision from geometry instead of from a guess,
#   * the VERIFIER can reject an arm whose domain is empty (see `ZONE_DOMAIN_GATE`), and
#   * an experiment can report WHY a decision was what it was.
#
# It is a thin composition over functions that already exist in `restage_zone.jl` -- no new
# geometry is invented here.
#
# THE TEAM-SLOT PREDICATE, AND WHY IT IS *NOT* A `ReformTeam` BRANCH
# ------------------------------------------------------------------
# A forming transport team is the fourth thing a zone can invalidate: its members must reach
# prescribed carrying slots around the cargo (`global_transform(tu) ∘ child_transform(tu, mid)`),
# and a zone over those slots makes the team unformable. The first three predicates miss this
# entirely -- an already-started assembly contributes nothing to `blocked`, so a zone sitting on
# its gather point scored `n_blocked = 0, root_covered = 0` and the rule called it `:noop` while
# the build was in fact wedged. That false `:noop` is the corridor/clearance blind spot.
#
# It is computed here (over `_forming_teams`, whose `RobotGo`-chain traversal is what makes the
# root-endgame team visible at all), but it does NOT produce a `ReformTeam` verdict. `ReformTeam`
# enacts by SNAPPING robots into those slots, and `recover_stalled_teams!` step 2 explicitly
# refuses to do that when the gather point is inside a no-go zone -- it would place robots in the
# forbidden region. That same step shows what the repair actually is: `restage_all_blocked!`,
# falling back to `translate_whole_build!`. So a covered team routes to the SPATIAL arm, exactly
# like every other violation here. `ReformTeam` stays what `verify_reform` says it is: a reactive
# response to an ALREADY-wedged team (`ready>=1 && missing>=1`), which a zone decision taken
# before the stall cannot anticipate.
#
# [한국어] 이 파일은 "no-go 구역이 씬트리의 무엇을 무효화하는가"를 계산하는 술어 모음이다.
#   재명세 액션 공간은 씬트리(어느 적치영역이 어디 있는가)인데 ForbidZone 은 항법 공간의 제약이라,
#   둘은 오직 씬트리가 작업공간에 남기는 "이미지"(적치원 · root 하역목표 · 미완 작업 디스크 ·
#   형성 중인 팀의 운반 슬롯)를 통해서만 만난다. 구역이 그중 아무것도 무효화하지 않으면 반응형
#   회피층이 그냥 우회하고, 그때 NOOP 은 퇴화가 아니라 **참으로 옳은 답**이다.
#   기하는 거의 만들지 않는다 — restage_zone.jl · replace_robot.jl 의 기존 함수들을 조합한다.
#   **팀 슬롯 술어**: 이미 시작된 조립체는 blocked 에 안 잡히므로, 그 집결지를 덮은 구역은
#   n_blocked=0 · root_covered=0 이 되어 옛 규칙이 :noop 이라 답했다 — 빌드는 실제로 끼어 있는데도.
#   그 거짓 :noop 이 corridor/clearance 사각지대다. 단, 이 술어는 **ReformTeam 분기가 아니다**:
#   ReformTeam 은 슬롯으로 로봇을 순간이동시키는데, recover_stalled_teams! 2단계가 "집결지가
#   금지구역이면 snap 금지 → restage/translate" 라고 이미 못박아 두었다. 즉 덮인 팀의 수복은
#   공간형 팔이다. ReformTeam 은 verify_reform 의 정의대로 **이미 끼인** 팀에 대한 사후 대응으로 남는다.
# =============================================================================

"""
    zone_team_coverage(env, center, radius; margin) -> Vector{NamedTuple}

For every transport team that is CURRENTLY forming, how much of it the disc `(center, radius)`
swallows. One entry per team:

| field | meaning |
|---|---|
| `unit` | the `TransportUnit`'s node id |
| `ready` / `missing` | members already within capture distance / still en route |
| `gather` | the unit's 2D position — where the team must converge |
| `gather_in_zone` | `gather` is inside the disc (+`margin`) |
| `n_slots` / `n_slots_in_zone` | prescribed carrying slots, and how many the disc covers |
| `covered` | `gather_in_zone || n_slots_in_zone > 0` — this team cannot form where it stands |

Slots are the SAME geometry `reform_stuck_teams!` snaps to (`global_transform(tu) ∘
child_transform(tu, mid)`), so "covered" here means precisely "the snap this zone would force
is the one `recover_stalled_teams!` refuses to perform".

Read-only. Empty when nothing is forming — a zone raised between batches sees no team, which is
the honest answer, not a failure.
"""
# 지금 형성 중인 각 운반팀을 원판(center, radius)이 얼마나 삼키는지 계산(읽기 전용).
#   gather = 팀이 모여야 하는 지점(운반유닛 위치), slots = 각 팀원이 짐을 드는 정확한 자리.
#   슬롯 기하는 reform_stuck_teams! 이 실제로 snap 하는 그 좌표와 **동일**하다 → covered=true 는
#   "이 구역이 강요하는 snap 이 바로 recover_stalled_teams! 이 거부하는 그 snap 이다" 라는 뜻.
#   형성 중인 팀이 없으면 빈 목록(배치 경계에서 뜬 구역은 팀을 못 본다 — 실패가 아니라 정직한 답).
function zone_team_coverage(env, center, radius::Real; margin::Float64 = default_robot_radius())
    out = NamedTuple[]
    c = Vector{Float64}(center[1:2]); r = Float64(radius)
    teams = try
        _forming_teams(env)
    catch e
        @warn "[ZONE-DIAG] _forming_teams failed" exception = e
        return out
    end
    for t in teams
        tu = t.tu
        gin = norm(Vector{Float64}(t.gather) .- c) < r + margin      # 집결지가 구역 안인가
        n_slots = 0; n_in = 0
        team = try robot_team(tu) catch; nothing end
        if team !== nothing
            for (mid, _) in team
                has_component(tu, mid) || continue                   # 이 유닛이 실제로 데리고 있는 팀원만
                p = try
                    # reform_stuck_teams! 이 snap 목표로 쓰는 바로 그 변환(∘ = 변환 합성).
                    Vector{Float64}((global_transform(tu) ∘ child_transform(tu, mid)).translation[1:2])
                catch
                    continue
                end
                n_slots += 1
                norm(p .- c) < r + margin && (n_in += 1)
            end
        end
        push!(out, (unit = node_id(tu), ready = t.ready, missing = t.missing,
                    gather = Vector{Float64}(t.gather), gather_in_zone = gin,
                    n_slots = n_slots, n_slots_in_zone = n_in,
                    covered = gin || n_in > 0))
    end
    return out
end

"""
    zone_diagnosis(env, zone::Symbol; margin, check_restage=true, check_teams=true) -> NamedTuple

Which scene-tree entities the live restriction zone `zone` invalidates, plus the cheapest
repair that can actually clear them.

Returned fields — PRIMITIVES first, VERDICT last:

| field | meaning | source |
|---|---|---|
| `exists` | `zone` is a live key of `RESTRICTION_ZONES` | — |
| `center`, `radius` | the zone's geometry | — |
| `blocked` | ids of assemblies a `ForbidZone` could relocate NOW (non-root ∧ not started ∧ not active) | `zone_blocked_assemblies` |
| `n_blocked` | `length(blocked)` — **0 means the `ForbidZone` arm is a silent no-op** | — |
| `feasible` | the subset of `blocked` with a zone-clear, non-overlapping spot to move to — a caller that must NAME a `ForbidZone` target takes one from here | `find_clear_staging_center` |
| `n_restage_feasible` | `length(feasible)` | — |
| `root_covered` / `root_total` / `root_frac` | root deposit goals swallowed — the goals NO per-assembly restage can rescue | `root_goal_coverage` |
| `n_work_overlap` | unfinished work discs overlapping the zone (severity proxy) | `_count_future_work_overlaps` |
| `teams` | per-forming-team coverage detail | `zone_team_coverage` |
| `n_teams_forming` / `n_teams_covered` | teams currently forming / of those, unformable where they stand | — |
| `n_nav_goals` | unfinished goals an RVO-DRIVEN agent must reach — the only goals a zone can physically block (`-1` if not computed) | `zone_blockage` |
| `n_nav_engulfed` / `n_nav_disconnected` | of those, goals whose capture ball is inside the exclusion disc / goals still free but with no surviving route | 〃 |
| `n_nav_blocked` | their sum: **nodes that cannot close while this zone lives**. Every other count above is COVERAGE; this one is BLOCKAGE | 〃 |
| `n_nav_downstream` | unfinished nodes that are blocked or transitively wait on one — how much work the blockage freezes (a precedence-graph fact, not a judgement) | 〃 |
| `n_completion_blocked` / `n_completion_open` | still-open `ProjectComplete` vertices inside that closure / in the whole schedule. `project_complete(env)` is exactly "every one of these is closed", so the first being `>= 1` is TERMINALITY, not slowdown | 〃 |
| `project_blocked` | `n_completion_blocked >= 1`, or **`nothing` when it could not be computed** (three-state; never `false` for "not measured") | 〃 |
| `n_agent_trapped` | movers standing inside the zone right now (parked when it appeared) | 〃 |
| `relocate_delta` / `relocate_norm` | the minimum rigid whole-build shift that clears the zone (`nothing` if none exists) | `_find_min_translation` |
| `relocate_feasible` | a clearing shift exists | — |
| `verdict` | the cheapest repair that clears every violated predicate | see below |

`verdict` is one of:

  * `:no_such_zone`   — `zone` is not registered; nothing to diagnose.
  * `:forbid_zone`    — at least one blocked assembly can be restaged locally. This is
    preferred over `:relocate_build` even when root goals are ALSO covered, because
    `restage_all_blocked!` reports `:residual_blocked` in that case and `maybe_respecify!`
    ESCALATES to `translate_whole_build!` automatically — so choosing the local arm never
    forfeits the global one.
  * `:relocate_build` — no assembly can be restaged, but the zone swallows something no local
    restage can rescue — root deposit goals, or the gather point / carrying slots of a team
    that is trying to form — and a clearing shift exists. The whole-build move is chosen
    DIRECTLY here. (Until 2026-09-22 the escalation above was unreachable on an empty domain,
    because `restage_all_blocked!` early-returned `:none` without computing the residual. It
    now reports `:residual_blocked` there when a goal is blocked, so `maybe_respecify!` also
    escalates; the label rule is unchanged.)
  * `:line_stop`      — root goals (or a forming team) are trapped and no rigid shift clears
    the zone. Genuinely unrecoverable; the caller must engage the safe fallback.
  * `:noop`           — the zone blocks no goal the schedule still needs (or only blocks
    already-started assemblies while leaving root goals and every forming team clear). The
    motion stack routes around it. Measured on the tractor twin with the macro crossed on the
    same seed and zones: restraint closed **231** nodes (7/8 assemblies), a whole-build move
    closed **136** (1/8). Intervening here is not neutral — it is actively harmful.

Set `check_teams=false` to reproduce the pre-team-predicate rule exactly (labels dumped before
the predicate existed were generated that way).

!!! note "This is the LABEL, not the model input"
    `verdict` implements the reference decision rule, so it belongs to the ORACLE and to the
    gate. Handing it to a policy as an input feature would mean the policy is reading the
    answer rather than inferring it; give a policy the PRIMITIVE fields instead.

`check_restage=false` skips the per-assembly `find_clear_staging_center` scan (the only
non-trivial cost here); `n_restage_feasible` is then reported as `n_blocked`.
"""
# 한 구역이 씬트리의 무엇을 무효화하는지 + 그걸 실제로 치울 수 있는 가장 싼 수복이 무엇인지 계산한다.
# 반환은 NamedTuple: 앞쪽은 원시값(primitive), 마지막 `verdict` 만 판정이다.
#   :forbid_zone    = 국소 재적치 가능(root 도 덮였더라도 이쪽이 우선 — 부족하면 실행부가 자동 격상함)
#   :relocate_build = 국소로 옮길 게 하나도 없는데 **국소로는 못 구하는 것**(root 하역목표 또는 형성 중인
#                     팀의 집결지/운반슬롯)이 갇힘 → 직접 전역 이동. (2026-09-22 전에는 restage_all_blocked! 이
#                     :none 으로 조기 반환해 자동 격상이 도달 불가였다; 이제 막힘이 있으면 :residual_blocked 를 낸다)
#   :line_stop      = 갇혔는데 어떤 강체이동으로도 못 벗어남 → 안전 폴백
#   :noop           = 스케줄이 아직 필요로 하는 목표를 아무것도 안 막음 → 항법이 우회. 개입은 해롭다(231 vs 136 실측)
# 주의: verdict 는 **정답(라벨)**이지 모델 입력이 아니다. 정책에 주면 추론이 아니라 답을 읽는 것이 된다.
function zone_diagnosis(env, zone::Symbol;
        margin::Float64 = default_robot_radius(),
        check_restage::Bool = true,
        check_teams::Bool = true,
        check_blockage::Bool = true,
        check_paths::Bool = get(ENV, "ZONE_CHECK_PATHS", "0") == "1")
    _ablation_gate(:zone_diagnosis)   # 존 복구 base ablation(명세 §6 층 3) — 무장·차단 레벨에서만 던진다

    # ---- 0. 구역이 살아 있는가 -------------------------------------------------
    if !haskey(RESTRICTION_ZONES[], zone)
        return (zone = zone, exists = false, center = nothing, radius = 0.0,
                blocked = AbstractID[], n_blocked = 0,
                feasible = AbstractID[], n_restage_feasible = 0,
                root_covered = 0, root_total = 0, root_frac = 0.0,
                n_work_overlap = 0,
                teams = NamedTuple[], n_teams_forming = 0, n_teams_covered = 0,
                n_nav_goals = 0, n_nav_blocked = 0, n_nav_engulfed = 0,
                n_nav_disconnected = 0, n_agent_trapped = 0, n_nav_downstream = 0,
                # 🔴 삼상: 진단할 구역이 없으므로 **안 쟀다**. 0/false 가 아니라 nothing 이다.
                n_completion_blocked = nothing, n_completion_open = nothing,
                project_blocked = nothing,
                relocate_delta = nothing, relocate_norm = Inf, relocate_feasible = false,
                verdict = :no_such_zone)
    end
    ball = RESTRICTION_ZONES[][zone]
    zc = Vector{Float64}(get_center(ball)[1:2])   # 구역 중심(x,y)
    zr = Float64(get_radius(ball))                # 구역 반지름

    # ---- 1. staging 위반: ForbidZone 이 지금 실제로 옮길 수 있는 집합 ----------
    # zone_blocked_assemblies 는 root 도 아니고 아직 시작도 안 한 조립체만 센다 = 이 팔의 진짜 도메인.
    blocked = try
        zone_blocked_assemblies(env; zone_keys = [zone], margin = margin)
    catch e
        @warn "[ZONE-DIAG] zone_blocked_assemblies failed for :$(zone)" exception = e
        AbstractID[]
    end
    n_blocked = length(blocked)

    # 그중 실제로 옮겨 놓을 빈 자리가 있는 것들(= restage 가 성공할 수 있는 조립체).
    # 개수만이 아니라 **id 목록**을 돌려주는 이유: ForbidZone 은 대상 조립체를 지목해야 하는데,
    # 사건 문맥(ZoneTruth)이 대상을 안 실어줄 때가 있다. 그때 여기 첫 원소를 쓰면 "대상이 없어서
    # 조용히 NOOP" 이 되는 구멍(=오답이 절제처럼 보이는 그 구멍)이 닫힌다.
    # 이 스캔이 이 함수에서 유일하게 값비싼 부분이라 끄고 부를 수 있게 해 둔다.
    feasible = if !check_restage
        blocked
    else
        filter(blocked) do aid
            try
                R = Float64(get_radius(env.staging_circles[aid]))
                find_clear_staging_center(env, aid, R; zone_keys = [zone]) !== nothing
            catch
                false
            end
        end
    end
    n_feasible = length(feasible)

    # ---- 2. root 위반: 국소 재적치로는 절대 못 구하는 목표 ---------------------
    # root 는 빌드의 기준 프레임이라 절대 안 움직인다 → 그 하역 목표가 갇히면 조립체를 아무리 옮겨도 소용없다.
    rc = try
        root_goal_coverage(zc, zr, env)
    catch e
        @warn "[ZONE-DIAG] root_goal_coverage failed for :$(zone)" exception = e
        (covered = 0, total = 0, frac = 0.0)
    end

    # ---- 3. 심각도 대리치: 구역과 겹치는 미완 작업 디스크 수 -------------------
    n_overlap = try
        _count_future_work_overlaps(env; zone_keys = [zone])
    catch e
        @warn "[ZONE-DIAG] _count_future_work_overlaps failed for :$(zone)" exception = e
        0
    end

    # ---- 3b. 팀 슬롯 위반: 형성 중인 팀이 이 구역 때문에 못 모이는가 -----------
    # 이미 시작된 조립체는 blocked 에 안 잡히므로 위 1·2 번이 통째로 놓치는 위반 종류다.
    # (덮인 팀의 수복은 ReformTeam 이 아니라 공간형 팔이다 — 파일 상단 주석 참조.)
    teams = check_teams ? zone_team_coverage(env, zc, zr; margin = margin) : NamedTuple[]
    n_teams_covered = count(t -> t.covered, teams)

    # ---- 3c. 막힘(blockage) 술어: 이 구역이 **실제로** 못 닫게 만드는 노드가 있는가 ----
    # 위 1·2·3b 는 전부 "덮였다"(coverage)를 잰다. STEP 6 실측이 보여준 대로 덮임은 해로움이 아니다:
    # root 하역목표를 8/8 삼켜도 빌드는 완주했다(시간만 2.1배). 이유는 그 목표들이 LiftIntoPlace 의
    # 목표 = **화물을 직접 옮기는** 노드라 RVO 를 안 거치고, 구역 강제는 RVO 에이전트만 스냅하기 때문.
    # 그래서 여기서 "막을 수 있는 목표"(RobotGo/TransportUnitGo)만 따로 세어 원시값으로 싣는다.
    # (zone_corridor.jl 참조. 기본은 engulf 만 = 정확한 하한이고 싸다; 통로 연결성은 opt-in.)
    blk = check_blockage ?
        (try zone_blockage(env; zone_keys = [zone], check_paths = check_paths)
         catch e
            @warn "[ZONE-DIAG] zone_blockage failed for :$(zone)" exception = e
            nothing
         end) : nothing
    n_nav_goals   = blk === nothing ? -1 : blk.n_nav_goals
    n_nav_eng     = blk === nothing ? -1 : blk.n_engulfed
    n_nav_disc    = blk === nothing ? -1 : blk.n_disconnected
    n_nav_blocked = blk === nothing ? -1 : blk.n_blocked
    # 🔴 삼상 규약. `check_blockage=false` 이거나 `zone_blockage` 가 던졌으면 `blk === nothing`
    #    이고 그때 이 셋은 **없음(nothing)** 이다 — 0/false 로 접으면 "완주는 막히지 않았다"는,
    #    재지도 않은 주장이 된다.
    n_comp_blocked = blk === nothing ? nothing : blk.n_completion_blocked
    n_comp_open    = blk === nothing ? nothing : blk.n_completion_open
    proj_blocked   = blk === nothing ? nothing : blk.project_blocked
    n_trapped     = blk === nothing ? -1 : blk.n_agent_trapped
    n_nav_down    = blk === nothing ? -1 : blk.n_downstream

    # ---- 4. 전역 이동이 가능한가 + 그 비용(Δ 크기) ----------------------------
    # 실행부(translate_whole_build!)와 **같은 솔버**로 묻는다 → 여기서 나온 Δ 가 곧 실제 이동량.
    Δ = try
        _find_min_translation(env; zone_keys = [zone])
    catch e
        @warn "[ZONE-DIAG] _find_min_translation failed for :$(zone)" exception = e
        nothing
    end
    relocatable = Δ !== nothing
    Δnorm = relocatable ? norm(Δ) : Inf

    # ---- 5. 최소 수복 판정(정정된 결정 표) -----------------------------------
    # ZONE_CAUSAL_RULE=1 (opt-in): 개입 조건을 **커버리지가 아니라 막힘**으로 바꾼다.
    #   STEP 6 이 반증한 것은 규칙의 기하가 아니라 **인과**였다 — root 를 덮었다는 사실만으로 개입하면
    #   8판 중 7판이 완주에 실패했다(개입이 피해보다 큰 손해). 그래서 "실제로 못 닫는 노드가 하나라도
    #   있을 때만" 개입한다. 기본이 꺼짐인 이유는 옛 라벨/게이트 재현성이며, 켤 근거는 STEP 10 의
    #   대조 실험(막는 zone 을 만들어 NOOP 이 실제로 실패함을 보이는 것)이다.
    #
    # ★ 이 규칙은 커버리지를 **완전히 무시**한다. 둘을 섞으면(예: "덮였고 그리고/또는 막혔으면")
    #   STEP 10 이 잡아낸 두 오답이 그대로 남는다:
    #     · root 를 덮었지만 아무것도 안 막는 구역 → 개입(측정: 8판 중 7판 미완주)
    #     · root 를 하나도 안 덮지만(root_covered=0, domain=0) nav 목표 3개를 막는 구역 → 절제
    #       (측정 2026-08-05 `blk_noop`: 완주 실패, closed 254/289 에서 정체)
    #   두 번째가 결정적이다 — 커버리지 기반 규칙은 그 사건을 **볼 수단 자체가 없다**.
    causal = get(ENV, "ZONE_CAUSAL_RULE", "0") == "1"
    verdict = if causal && n_nav_blocked >= 0
        if n_nav_blocked == 0
            # 막을 수 있는 목표를 하나도 안 막았다 → 덮였더라도 항법이 우회한다. 개입은 순손실.
            :noop
        elseif n_feasible > 0
            :forbid_zone            # 국소 재적치로 치울 수 있으면 그게 가장 싸다(부족하면 실행부가 자동 격상)
        elseif relocatable
            :relocate_build         # 국소 도메인이 비었으면 전역 이동을 직접 골라야 한다
        else
            :line_stop              # 막혔는데 어떤 강체이동으로도 못 벗어남 → 안전 폴백
        end
    elseif n_feasible > 0
        # 국소로 옮길 게 있으면 국소가 먼저다. root 까지 덮였으면 restage_all_blocked! 이
        # :residual_blocked 를 돌려주고 maybe_respecify! 가 알아서 전역 이동으로 격상한다.
        :forbid_zone
    elseif rc.covered > 0 || n_teams_covered > 0
        # 도메인이 비었다 → 전역 이동을 직접 고른다. (2026-09-22 전에는 :none 조기 반환 탓에 자동 격상이
        # 도달 불가였다; 지금은 막힘이 있으면 restage_all_blocked! 이 :residual_blocked 를 내 격상도 된다.)
        # 팀이 덮인 경우도 같은 팔이다: recover_stalled_teams! 2단계가 "집결지가 금지구역이면
        # snap 금지 → restage/translate" 로 이미 그렇게 정해 두었다(ReformTeam 이 아니다).
        relocatable ? :relocate_build : :line_stop
    else
        # 스케줄이 아직 필요로 하는 목표를 아무것도 막지 않는다 → 반응형 회피층이 우회한다.
        # 여기서 전역 이동을 고르면 순손실이다(231·7/8 vs 136·1/8 실측).
        :noop
    end

    return (zone = zone, exists = true, center = zc, radius = zr,
            blocked = blocked, n_blocked = n_blocked,
            feasible = feasible, n_restage_feasible = n_feasible,
            root_covered = rc.covered, root_total = rc.total, root_frac = rc.frac,
            n_work_overlap = n_overlap,
            teams = teams, n_teams_forming = length(teams), n_teams_covered = n_teams_covered,
            n_nav_goals = n_nav_goals, n_nav_blocked = n_nav_blocked,
            n_nav_engulfed = n_nav_eng, n_nav_disconnected = n_nav_disc,
            n_agent_trapped = n_trapped, n_nav_downstream = n_nav_down,
            n_completion_blocked = n_comp_blocked, n_completion_open = n_comp_open,
            project_blocked = proj_blocked,
            relocate_delta = Δ, relocate_norm = Δnorm, relocate_feasible = relocatable,
            verdict = verdict)
end

"""
    zone_diagnoses(env; check_restage=true, check_teams=true) -> Vector{NamedTuple}

[`zone_diagnosis`](@ref) for every currently registered zone, in `RESTRICTION_ZONES` order.
Empty when no zone is active — so a non-spatial event naturally sees nothing.
"""
# 현재 등록된 모든 제한구역에 대해 zone_diagnosis 를 돌려 목록으로 반환. 활성 구역이 없으면 빈 목록.
zone_diagnoses(env; check_restage::Bool = true, check_teams::Bool = true) =
    [zone_diagnosis(env, k; check_restage = check_restage, check_teams = check_teams)
     for k in keys(RESTRICTION_ZONES[])]
