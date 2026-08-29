# =============================================================================
# enact.jl -- 매크로 집행 사슬 하나. `run_demo.jl` 의 `handle_ood!` 안에 인라인으로 있던
# 블록을 **그대로** 옮긴 것이다(2026-08-29, Plan B / T2, 커밋 1 = 순수 이동).
#
# 왜 옮겼는가 (컨트롤러 판정 R5)
# ------------------------------
# `run_demo.jl` 은 최상위에서 데모를 통째로 돌리는 **스크립트**다(파일 끝이
# `println("[run_demo] DONE ...")` 이고 가드가 없다). 그래서 테스트가 include 할 수 없고,
# 사슬이 거기 있는 한 T2 의 게이트는 **생산 코드를 한 줄도 태울 수 없다** — 순수 함수만 재는
# 게이트가 되고, 그건 Plan A 가 이미 밟은 결함이다("실패할 수 없는 게이트").
#
# 🔴 **이 파일은 최상위 부작용이 없다.** 함수 정의뿐이다 — 테스트가 `using ConstructionBots`
# 뒤에 include 할 수 있어야 하기 때문이다. include 하는 쪽이 `const CB = ConstructionBots` 를
# 이미 정의하고 있어야 한다(`run_demo.jl:38` 과 게이트 파일이 둘 다 그렇게 한다).
#
# 🔴 **이동은 순수해야 한다**: 조건·순서·분기 본문·로그 문구·`enact_applied` 가 가드
# **안쪽**에 있는 것(2026-08-17 재리뷰 C1(B) 가 고친 것 — `ReformTruth` 는 필드가 없는 struct
# 이고 `ZoneTruth` 에는 `robot` 필드가 없어서, 가드 밖에 두면 거짓 보고가 난다) · MILP 센티넬
# 판정 · `_applied_note` 전부 그대로다. 검증 방법은 T2 보고서에 있다(HEAD 의
# `run_demo.jl:373-487` 를 그대로 뽑아 이 파일의 같은 구간과 `diff` — 0줄 차이).
# =============================================================================

"""
    _arm_overridden(router) -> Bool

이 결정의 **집행 팔이 정책 밖에서 강제로 갈아 끼워졌는가**(통제 실험 `DEMO_FORCE_MACRO`,
또는 1-step deviation `DS_DEVIATE_AT`).

🔴 왜 이것이 집행 대상 선택에 필요한가 (T1 리뷰 F8 · 컨트롤러 판정 R16)
------------------------------------------------------------------------
`decide_all` 은 `tool_lane` 을 `pol[enacted]` 에서 **`FORCE_MACRO`/`DEVIATE` 가 `chosen` 을
덮기 전에** 뽑는다(`policy.jl` 의 `forced`/`dev` 블록이 `tool_lane` 을 만드는 줄보다 앞이
아니다 — 뒤다). 그래서 통제 판·이탈 판에서는 `decision.macro_name` 과
`tool_lane["tool_called"]` 이 **서로 다른 팔**을 서술한다: 집행되는 것은 강제된 팔이고,
tool 호출은 정책이 원래 고른 팔의 것이다.

그 상태에서 `tool_args["agent"]` 를 그대로 집행에 먹이면, **한 팔을 위해 고른 agent 가 다른
팔의 집행에 적용**되고 결정 행은 그것을 `enact_agent_source == "tool"` 로 주장한다 — 이
태스크가 없애려는 바로 그 종류의 조용한 거짓말이다.

**해법은 추측이 아니라 거절이다(R16).** 팔이 강제됐으면 `truth.robot` 으로 떨어지고
`"truth"` 로 기록한다. 강제된 팔이 "원했을" agent 를 재유도하지 않는다 — 통제 판의 존재
이유가 팔이 외부에서 부과됐다는 것이고, LLM 의 파라미터가 그 팔에 얹혀 가면 통제가 오염된다.
대가: 통제·이탈 판은 tool-agent 경로를 한 번도 안 태운다 — 통제로서는 그게 맞는 동작이다.

무엇을 보는가(전부 **값**으로 판정한다):
  * `router["forced_from"]`  -- `FORCE_MACRO` 가 실제로 팔을 갈아 끼웠다(`policy.jl:1422`)
  * `router["deviate_from"]` -- deviate 게이트가 이 인덱스에서 발화했다(`:1436`)
  * `router["deviated"]`     -- 그 발화가 실제로 팔을 바꿨다(`:1435`)
  * `ENV["DEMO_FORCE_MACRO"]` -- 🔴 `forced` 는 `FORCE_MACRO != chosen` 일 때만 참이라
    (`:1419`), 강제 팔이 우연히 정책의 선택과 같으면 `forced_from` 이 **안 실린다.** 그래도
    그 판은 통제 판이다 — R16 이 env 도 같이 보라고 못박은 자리다.
"""
function _arm_overridden(router)
    isempty(strip(get(ENV, "DEMO_FORCE_MACRO", ""))) || return true
    router === nothing && return false
    get(router, "forced_from", nothing) === nothing || return true
    get(router, "deviate_from", nothing) === nothing || return true
    return get(router, "deviated", false) === true
end

"""
    enact_target(env, truth, tool_lane, router) -> (; agent, source, tool_agent)

**누구에게 집행할 것인가**를 정한다. Plan B 의 분수령이 이 함수다 — 여기가 `truth.robot` 을
돌려주면 집행은 주입기가 이미 아는 값을 쓰는 것이고, LLM 의 tool 호출은 세계에 대해
인과가 없다.

규칙 (브리프 커밋 3 + 컨트롤러 판정 R16):
 0. 이 결정의 팔이 강제/이탈로 갈아 끼워졌으면(`_arm_overridden`) tool 레인을 **안 본다**.
 1. `tool_lane["tool_args"]["agent"]` 가 **문자열**이고
 2. `CB.resolve_agent_id(env, 그 문자열)` 이 `nothing` 이 아니면 → 그것을 쓴다. source `"tool"`.
 3. 아니면 `truth.robot`(있으면). source `"truth"`.
 4. `truth` 에 `robot` 이 없으면 agent `nothing`, source `"none"`.

🔴 **폴백은 반드시 기록된다 (컨트롤러 판정 R2/R6).** 조용히 떨어지면 "LLM 이 골랐다" 와
"주입기가 알려줬다" 가 **같은 관측**이 되고, Plan B 가 재려는 것 자체가 측정 불가가 된다.
그래서 이 함수는 `source` 와 **원문 문자열** `tool_agent` 를 함께 낸다 — `handle_ood!` 이
셋을 결정 행에 싣는다(`tool_agent` · `enact_agent` · `enact_agent_source`).

⚠️ `tool_agent` 는 팔이 강제된 판에서도 **원문 그대로** 실린다. 그래야 "LLM 은 B 를 냈는데
집행은 A 로 갔다" 가 산출물에서 보인다 — 원문을 지우면 R16 의 거절이 tool 레인 부재와
구분되지 않는다.

🔴 **키 존재로 분기하지 않는다 (T1 이 남긴 소비자 규칙 1).** `decide_all` 은 8키를
`get(..., nothing)` 으로 순회하므로 **키는 항상 있고** 값만 `nothing` 일 수 있다 —
`haskey` 는 값이 실려 왔다는 증거가 아니다. 그래서 여기서 보는 것은 **값**뿐이다.

⚠️ **`tool_lane` 만으로는 "레인이 실패했다" 와 "레인이 없었다" 를 못 가른다**(T1 리뷰 R1:
폴백 `policy_entry` 가 측정된 `tool_lane_error` 를 `nothing` 으로 접는다). 이 함수는 그
구분이 필요 없다 — 둘 다 "agent 를 못 얻었다" 로 같게 처리하고 `"truth"` 로 기록한다.
그 구분이 필요한 소비자는 정책 항의 `available`/`error` 를 봐야 한다.

⚠️ **`tool_args` 변환은 얕다 (T1 소비자 규칙 2).** 오늘 tool 알파벳의 인자는 전부 평평한
문자열 하나라(`tool_registry.py` 의 `_agent_arg()` — enum 의 키가 `"agent"` 다) 여기서 읽는
`tool_args["agent"]` 는 `String` 이다. 중첩 인자를 받는 tool 이 생기면 그 값은
`JSON3.Object` 로 남고, 그때 이 가정을 다시 읽어야 한다. `raw isa AbstractString` 검사가
그 순간의 안전장치다 — 문자열이 아니면 tool 레인이 없는 것과 같이 취급한다.
"""
function enact_target(env, truth, tool_lane, router)
    # 값을 본다 — 키 존재가 아니라. `tool_lane` 자체가 없을 수도 있는 호출자를 위해 get 을 쓴다.
    local ta = tool_lane === nothing ? nothing : get(tool_lane, "tool_args", nothing)
    local raw = ta isa AbstractDict ? get(ta, "agent", nothing) : nothing
    local tool_agent = raw isa AbstractString ? String(raw) : nothing
    # R16: 팔이 강제/이탈로 갈아 끼워진 판에서는 tool 레인의 agent 를 **쓰지 않는다.**
    local same_arm = !_arm_overridden(router)
    # 접지: 열거에 **정확히 있는** 문자열만 통과한다(`CB.resolve_agent_id`, 파싱 없음).
    local hit = (same_arm && tool_agent !== nothing) ?
        (try CB.resolve_agent_id(env, tool_agent) catch; nothing end) : nothing
    hit !== nothing &&
        return (agent = hit, source = "tool", tool_agent = tool_agent)
    hasproperty(truth, :robot) &&
        return (agent = truth.robot, source = "truth", tool_agent = tool_agent)
    return (agent = nothing, source = "none", tool_agent = tool_agent)
end

"""
    enact_macro!(env, truth, mac, agent) -> (; enact_applied, ran_milp)

고른 매크로 `mac` 을 세계에 집행한다. `agent` 는 **집행 대상 로봇**(`RobotID` 또는
`nothing`) — 누가 그 값을 고르는지는 `enact_target` 이 정한다(아래).

반환 둘은 `handle_ood!` 이 결정 행에 그대로 싣는 것이다:
  * `enact_applied` -- 사슬의 어느 분기가 **실제로** 탔는가. 이 사슬은 최종 `else` 가 없고
    두 zone 분기는 `truth isa CB.ZoneTruth` 가드가 걸려 있어서, 지원 안 하는 매크로로
    deviate 하면 아무 일 없이 통과하는데도 verdict 는 "집행했다"고 말할 수 있다.
  * `ran_milp`     -- G6(spec §5.5): 이 결정에서 f 가 솔버를 불렀는가(센티넬 판정).

`tag` 는 로그 문구용으로 여기서 다시 만든다 — `handle_ood!` 의 `tag` 와 **같은 식**이다
(`string(typeof(truth).name.name)`).
"""
function enact_macro!(env, truth, mac, agent)
    local tag = string(typeof(truth).name.name)
    # spec §9(a) 배터리/에너지 훅 활성 검사. 이 데모는 RESPEC_ENABLED=false 로 두고 복구를 직접
    # 몰기 때문에, replan.jl 의 `[RESPEC] ... energy term` 로그가 있는 maybe_respecify! 경로를
    # 타지 않는다. 그래서 여기서 직접 본다: 매크로 집행이 MILP 를 다시 정식화했다면
    # (rebalance_for_battery! 등) LAST_AUTO_EFFICIENCY_W[] > 0 이어야 한다 = 전역 κ 가 그 재풀이에도
    # 실렸다는 뜻. (0 으로 먼저 지워야 이전 결정의 값이 새 나가지 않는다 — Ref 는 sticky 하다.)
    #
    # ⚠️ 세 상태를 구분해야 한다(리뷰 I-3). n_candidate_edges=0 은 "재풀이는 했는데 후보가 없었다"
    #   와 "재풀이 자체가 없었다"를 구별하지 못한다 — Replace/ReformTeam/RelocateBuild 는
    #   formulate_milp 을 아예 안 부르므로 항상 후자다. 그래서 센티넬 Dict 를 심어 둔다:
    #   formulate_milp 이 돌면 LAST_EDGE_COSTS[] 를 **새 Dict 로 교체**하므로 `===` 가 깨진다.
    local _milp_sentinel = Dict{Tuple{Int,Int},Float64}()
    CB.LAST_AUTO_EFFICIENCY_W[] = 0.0
    CB.LAST_EDGE_COSTS[] = _milp_sentinel
    # 이 사슬은 최종 `else` 가 없고 두 분기는 `truth isa CB.ZoneTruth` 가드가 걸려 있다 — 그래서
    # 지원 안 하는 매크로(예: fault 사건에 ForbidZone)로 deviate 하면 사슬을 아무 일 없이 통과해
    # 세계가 안 바뀌는데도 verdict 는 "집행했다"고 말할 수 있다(2026-08-17 재리뷰 F2). 각 분기가
    # 실제로 탔는지를 여기 플래그로 남긴다 — 조건·순서·본문은 그대로, 계측만 얹는다.
    local enact_applied = false
    local ran_milp = false      # G6(spec §5.5): 이 결정에서 f 가 솔버를 불렀는가
    try
        if mac == "NOOP"
            enact_applied = true
            println("[recover] $tag → NOOP (정책이 개입하지 않기로 결정)")
        elseif mac == "Replace"
            # ⚠️ 2026-08-17 재리뷰 C1(B): `enact_applied` 는 **가드 안쪽**이어야 한다. `ReformTruth`
            # 는 필드가 없는 struct 이고(`src/navigator/ood_truth.jl:97-98`) `ZoneTruth` 에는
            # `robot` 필드가 없다(`:67-72`) — 가드 밖에 두면 reform/zone 사건에 Replace 로
            # deviate 했을 때 이 분기가 매치는 됐지만 `hasproperty` 가 false 라 아무 일도 안
            # 일어났는데 `enact_applied=true` 로 거짓 보고한다.
            #
            # 🔴 2026-08-29 (T2 커밋 3): 본체는 이제 `agent` 를 쓰지만 **가드는 그대로**
            # `hasproperty(truth, :robot)` 다(브리프·R5 가 조건 변경을 금한다). 귀결을 적어
            # 둔다: 가드가 참이면 `enact_target` 규칙상 `agent !== nothing` 이 보장되므로
            # nothing 역참조는 불가능하다. 반대 방향은 열려 있다 — `robot` 필드가 없는 truth
            # (ZoneTruth/ReformTruth)에 tool 이 유효 agent 를 실어 보내면 집행이 안 되고
            # `enact_applied=false` 로 **정직하게** 기록된다(조용한 거짓 보고가 아니다).
            if hasproperty(truth, :robot)
                enact_applied = true
                CB.hot_swap_robot!(env, agent; mode = :via_depot, verbose = false)
                if truth isa CB.BatteryTruth
                    local f = CB.BATTERY_FLEET[]                   # 스왑된 본체=새 배터리 → SoC 회복
                    (f !== nothing && haskey(f.soc, agent)) && (f.soc[agent] = 1.0)
                end
            end
        elseif mac == "SwapBattery"
            # 2026-08-06 (Ch-A): 현장 배터리 교체. Replace 와 달리 **창고 예비 본체를 안 먹는다** —
            # 그게 두 팔을 따로 두는 이유이고(spec_dsl.jl), 방전 사건에서 싼 정답이 되는 근거다.
            # 씬트리·스케줄을 안 건드리므로 정체성 위반이 원리적으로 불가능하다.
            # `enact_applied` 는 Replace 와 같은 이유로 가드 안쪽(2026-08-17 재리뷰 C1(B)).
            if hasproperty(truth, :robot)
                enact_applied = true
                local sw = CB.swap_battery!(env, agent; verbose = false)
                println("[battery] swap=$(sw.status) soc_before=$(get(sw, :soc_before, nothing))")
            end
        elseif mac == "ForbidZone" && truth isa CB.ZoneTruth
            enact_applied = true
            # A zone can cover several staging workspaces. Relocate every
            # blocked subassembly, then minimally translate the whole build
            # only if fixed/root goals remain covered. Keep the zone active so
            # routing and the post-RVO clearance gate enforce it continuously.
            local keys = Symbol[truth.zone]
            local staged = CB.restage_all_blocked!(env;
                zone_keys = keys, resume = true, verbose = false)
            local recovery = staged
            local overlaps = CB._count_future_work_overlaps(env;
                zone_keys = keys)
            local corrections = 0
            while overlaps > 0 && corrections < 4
                recovery = CB.translate_whole_build!(env;
                    zone_keys = keys, resume = true, verbose = false)
                corrections += 1
                recovery.status in (:translated, :already_clear, :residual_blocked) || break
                overlaps = CB._count_future_work_overlaps(env;
                    zone_keys = keys)
            end
            local residual = CB._count_future_work_overlaps(env;
                zone_keys = keys)
            residual == 0 || error(
                "zone recovery left $residual future work discs inside $(truth.zone)")
            println("[zone] staging=$(staged.status) final=$(recovery.status) " *
                    "corrections=$corrections active_zone=$(truth.zone) residual=$residual")
            # 좁은 공장에선 지속 존이 로봇 경로를 막아 nav 교착 → 조립체를 안전지대로 옮긴 뒤
            # 일시 장애를 해제(transient obstruction)해 완주시킨다. respec(ForbidZone)은 이미 기록됨.
        elseif mac == "RelocateBuild" && truth isa CB.ZoneTruth
            enact_applied = true
            # 2026-08-04: zone 사건의 기본 개입 팔. ForbidZone 분기와 달리 **조립체별 재적치를
            # 아예 건너뛰고** 빌드 전체를 한 번에 옮긴다(그 전제조건이 빌드 중반에 사라지므로).
            # 이 분기가 없으면 LLM 이 RelocateBuild 를 골라도 아무 일도 안 일어나고, UI 에는
            # "LLM 이 개입했다"고 찍히는 최악의 조용한 거짓말이 된다.
            local zkeys = Symbol[truth.zone]
            local wb = CB.translate_whole_build!(env; zone_keys = zkeys, resume = true, verbose = true)
            local left = CB._count_future_work_overlaps(env; zone_keys = zkeys)
            println("[zone] whole-build=$(wb.status) Δ=$(get(wb, :delta, nothing)) " *
                    "active_zone=$(truth.zone) residual_work_discs=$left")
            # :already_clear = Δ0. 구역이 미완 목표를 하나도 안 덮어 옮길 필요가 없었던 경우이며
            # 실패가 아니다(예전에는 :translated 로 뭉뚱그려져 "0 m 이동"이 성공으로 찍혔다).
            wb.status in (:translated, :already_clear) ||
                @warn "RelocateBuild 가 구역을 못 벗어남" status=wb.status residual=left
        end
        # enact_applied 가 false 면 위 "→ $mac" 은 거짓말이다 — 어느 분기도 안 탔다는 뜻이므로
        # 그 사실을 로그 문구 자체에 남긴다(2026-08-17 재리뷰 F2). 사슬의 조건·순서·본문은
        # 그대로다 — 이 줄만 계측이다.
        local _applied_note = enact_applied ? "" :
            " [집행 사슬 무동작: 이 사건 타입엔 $(mac) 분기가 없거나 가드에 안 걸렸다]"
        println("[recover] $tag → $mac$(_applied_note)  (closed=", length(env.cache.closed_set), ")")
        ran_milp = !(CB.LAST_EDGE_COSTS[] === _milp_sentinel)   # 센티넬이 그대로면 재풀이 없음
        if CB.LAST_AUTO_EFFICIENCY_W[] > 0.0
            println("[recover] energy term ON for this re-solve (auto w_eff=",
                    round(CB.LAST_AUTO_EFFICIENCY_W[]; sigdigits = 3),
                    ", κ=", CB.AUTO_EFFICIENCY_KAPPA[], ")")
        elseif !ran_milp
            println("[recover] energy term N/A for $mac — 이 분기는 formulate_milp 을 아예 부르지 ",
                    "않는다(재풀이 없음). κ 와 무관한 상태다")
        else
            println("[recover] energy term NOT active for $mac — 재풀이는 했다(κ=",
                    CB.AUTO_EFFICIENCY_KAPPA[], ", n_candidate_edges=",
                    length(CB.LAST_EDGE_COSTS[]),
                    "). 후보 엣지가 0 이면 재배정할 자유도가 없어 에너지 항이 실릴 데가 없다는 뜻이다")
        end
    catch e
        println("[recover] $tag ($mac) FAILED: ", first(split(sprint(showerror, e), "\n")))
    end
    return (enact_applied = enact_applied, ran_milp = ran_milp)
end
