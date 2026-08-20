# =============================================================================
#  zone_guard.jl -- NO-GO ZONE SAFETY AUDIT (measurement, not enforcement)
# =============================================================================
#
# WHAT ENFORCES THE NO-GO INVARIANT IN THIS REPO
# ----------------------------------------------
# Two mechanisms, both already in `route_planning.jl`, both already exercised by every run:
#
#   1. `enforce_restriction_zone_clearance!`  -- called from `step_environment!` AFTER the RVO
#      step. Any agent inside an active zone disc is snapped out to the boundary. This is the
#      hard invariant: no agent is ever OBSERVED inside a zone.
#   2. the `RESPEC_HOLD[]` line-stop -- `step_environment!` zeroes every RVO agent's preferred
#      velocity while the flag is up, so `engage_fallback!` physically holds the line.
#
# Neither one MEASURES anything, so a finished run could not say how close it came. That is
# what this file is for: it reports the margin, it does not create it.
#
# WHY THERE IS NO CBF LAYER HERE (read this before adding one back)
# -----------------------------------------------------------------
# `safety/cbf.jl` used to sit in this directory: a CBF-QP velocity filter (L1) plus a backup
# controller (L0), ~520 lines. It was removed on 2026-08-18 because it never ran and its stated
# justifications were measured false. The evidence, kept here so it is not rediscovered the
# hard way:
#
#   * DEAD IN THE WORKFLOW. `enable_cbf!()` was called from exactly two places, both of them
#     the filter's own harness (`tools/test_cbf.jl`, `tools/cbf_sim_eval.jl`). No demo, e2e,
#     monitor, navigator or respec path ever enabled it, so its single production call site
#     returned the commanded velocity unchanged on every step of every real run.
#   * NO MEASURABLE EFFECT WHEN IT *WAS* ENABLED. `tools/cbf_sim_eval.jl` ran CBF_ON vs CBF_OFF
#     at a fixed seed: both arms recorded 2 zone snaps at the identical depth 0.5513189724, and
#     the filter itself observed h < 0 ZERO times. The remaining violations were an INITIAL
#     CONDITION (a zone created on top of already-parked robots), which no velocity filter can
#     prevent. Across both evaluated scenarios there were zero DYNAMIC zone entries even with
#     the filter off -- TangentBug + the potential field already keep robots out.
#   * ITS L0 CLAIM WAS STALE. The filter's rationale was that `RESPEC_HOLD[]` was "a flag
#     nothing in the simulation loop ever reads". That has not been true since the line-stop
#     landed in `step_environment!`; the fail-closed path already had physical teeth, and the
#     opt-in that would have routed it through the filter (`set_failclosed_stop!`) was never
#     called from anywhere in the repo.
#
# A CBF layer is a reasonable thing to want, but it earns its place by changing a measured
# number. If one is reintroduced, gate the decision on `zone_clearance` below going somewhere
# it does not go today.
#
# -----------------------------------------------------------------------------
# [한국어 설명]
# 이 파일이 하는 일: 금지구역(no-go zone) 안전 여유를 **측정**한다. 강제하지는 않는다.
#
# 실제 강제는 이미 route_planning.jl 두 곳이 한다 —
#   (1) enforce_restriction_zone_clearance! : RVO 스텝 뒤 침범한 로봇을 경계로 밀어냄(하드 불변식)
#   (2) RESPEC_HOLD[] 라인스톱 : 플래그가 켜지면 매 스텝 모든 에이전트의 선호속도를 0 으로
# 둘 다 "얼마나 아슬아슬했는지"는 남기지 않아서, 그 여유를 재는 게 이 파일의 역할이다.
#
# 왜 CBF 를 뺐나: safety/cbf.jl(약 520줄)은 (a) 실제 워크플로에서 한 번도 켜진 적이 없고,
#   (b) 켜서 측정했을 때 CBF_ON/OFF 가 소수점 10자리까지 같았으며(필터가 관측한 위반 0건),
#   (c) 근거로 삼은 "RESPEC_HOLD 는 아무도 안 읽는 명목상 플래그"라는 서술이 이미 낡은 사실이었다.
#   다시 넣고 싶다면 아래 zone_clearance 수치가 실제로 달라지는지부터 보일 것.
# =============================================================================

"""
    zone_clearance(env) -> NamedTuple

Audit the CURRENT state: over every RVO-registered agent and every ACTIVE no-go zone, the
smallest clearance

    h = ||p - c|| - (R_zone + r_agent)

and how many agent/zone pairs are violating (`h < 0`). `min_clearance >= 0` is the runtime
EVIDENCE that the invariant held — report the measured margin rather than asserting safety from
the fact that an enforcement mechanism exists.

The geometry deliberately mirrors `enforce_restriction_zone_clearance!` exactly (same radius
lookup, same disc test), so this function measures what the simulator actually enforces. It is
read-only: it touches no RVO state and no scene tree.

`min_clearance` is `Inf` when there is nothing to measure (no zones or no agents).

(요약) 지금 상태의 최소 여유거리와 위반 쌍의 개수를 잰다. enforce_restriction_zone_clearance! 와
       완전히 같은 기하를 써서 "실제로 강제되는 것"을 재고, 상태는 전혀 건드리지 않는다.
"""
function zone_clearance(env)
    # `active_restriction_zones()` yields a lazy generator; collect once so it is iterated per
    # agent and counted without re-running the generator. (요약) 제너레이터라 한 번만 모아 둔다.
    zones = collect(active_restriction_zones())
    min_clear = Inf
    n_viol = 0
    n_agents = 0
    for id in get_vtx_ids(rvo_global_id_map())
        agent = try get_node(env.scene_tree, id) catch; continue end        # 장면트리에 없으면 건너뜀
        pos = try collect(Float64, rvo_get_agent_position(agent)) catch; continue end
        n_agents += 1
        ar = agent_disc_radius(agent)                                        # 에이전트 물리 반지름
        for (_, zone) in zones
            c = collect(Float64, get_center(zone)[1:2])                      # 구역 중심(x,y)
            d = norm(pos[1:2] .- c)                                          # 중심까지 거리
            h = d - (Float64(get_radius(zone)) + ar)                         # 여유거리(음수면 침범)
            h < min_clear && (min_clear = h)
            h < 0 && (n_viol += 1)
        end
    end
    return (min_clearance = min_clear, n_violations = n_viol,
            n_agents = n_agents, n_zones = length(zones))
end

"""
    agent_disc_radius(agent) -> Float64

The agent's physical disc radius, from its cached sphere geometry. Falls back to the fleet
default when an agent has no cached hypersphere (e.g. a transport unit spliced in mid-build) —
the same fallback `enforce_restriction_zone_clearance!` uses, so the two never disagree.
(요약) 에이전트 반지름. 캐시된 구 기하가 없으면 기본값 — 강제 코드와 같은 대체값을 쓴다.
"""
function agent_disc_radius(agent)
    try
        return Float64(get_radius(get_cached_geom(agent, HypersphereKey())))
    catch
        return Float64(default_robot_radius())
    end
end

"""
    zone_safety_report(env) -> String

One-line summary for the end of a run: the measured margin plus how much repair the snapper had
to do (`zone_snap_stats`, maintained by `enforce_restriction_zone_clearance!`).

`snapped` > 0 with `violations` == 0 is the normal healthy reading — it means the snapper
repaired transient overlaps and the state we ended in is clean. `violations` > 0 means an
active zone is being violated RIGHT NOW, which should not happen after a step and is worth a
look.

(요약) 실행 끝에 한 줄로 남기는 요약: 잰 여유거리 + 스냅퍼가 얼마나 손봤는지.
       snapped>0 & violations=0 이 정상. violations>0 이면 지금 이 순간 침범 중이라는 뜻.
"""
function zone_safety_report(env)
    c = zone_clearance(env)
    s = zone_snap_stats()
    return string("[ZONE] zones=", c.n_zones, " agents=", c.n_agents,
                  " min_clearance=", c.min_clearance == Inf ? "n/a" : round(c.min_clearance, digits = 4),
                  " violations=", c.n_violations,
                  " | snapper: calls=", s[:calls], " snapped=", s[:agents_snapped],
                  " max_depth=", round(s[:max_depth], digits = 4))
end
