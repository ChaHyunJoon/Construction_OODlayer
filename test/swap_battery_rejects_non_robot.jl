# test/swap_battery_rejects_non_robot.jl
# ============================================================================
#  이 파일이 지키는 것: **`swap_battery!` 는 로봇이 아닌 id 에 대해 성공을 보고하지 않는다**
#  (wave-b-review C1, 판정 R34).
#
#  결함(실측 2026-09-04, 이 파일의 픽스처로 재현): `swap_battery!`/`_apply_battery_swap!` 의
#  유일한 문지기가 `has_vertex(env.scene_tree, role)` 였다. 그런데 `TransportUnitNode` 는
#  씬트리 **안에 있다** — 그래서 운반유닛 id 가 문을 통과하고
#  `(status = :battery_swapped, soc_before = nothing)` 이 돌아왔다. 아무 로봇의 배터리도 안
#  갈렸는데 장부에는 `record_asset_swap!` 이 찍혔다. 즉 **조용한 거짓 성공**이다.
#
#  🔴 왜 이것이 게이트여야 하는가: 유료 런의 사다리는 `applied` · `world_maybe_dirty` ·
#     L4 `world_delta` 로 "모델이 세계를 옳게 바꿨다" 를 읽는다. 거짓 성공은 그 셋을 전부
#     움직이므로 **틀린 호출이 옳은 호출로 기록된다.** 프롬프트가 어떤 경로를 광고하든 이
#     결함은 독립적으로 존재하고, 문지기는 프롬프트와 달리 **항상 돈다.**
#
#  삼상: 로봇이면 `:battery_swapped`(예), 씬 노드가 없으면 `:no_robot`(아니오),
#        씬 노드는 있는데 로봇이 아니면 `:not_a_robot`(모른다/해당없음) — **셋이 구별된다.**
#        하나로 뭉치면 "왜 실패했나" 가 사라져 다음 세션이 다시 이 자리를 판다.
#
#  ⚠️ 픽스처는 `run_lego_demo` 를 안 부른다. `swap_battery!(env, role)` 의 `env` 는 무타입
#     인자이고 이 경로가 읽는 것은 `env.scene_tree` 하나다 — 그래서 진짜 `SceneTree` 에
#     진짜 `RobotNode` 하나와 진짜 `TransportUnitNode` 하나만 넣는다(리뷰가 실 `PlannerEnv`
#     에서 잰 것과 **같은 두 노드 부류**다). 씬을 안 지으므로 ~1s.
#
#  🔴 runtests.jl 이 모든 시험 파일을 같은 `Main` 스코프에 include 하므로 자기 module 로 감싼다.
# ============================================================================
module SwapBatteryRejectsNonRobotTests

using Test
using ConstructionBots
using Graphs
const CB = ConstructionBots

st = CB.SceneTree()
robot = CB.RobotNode(CB.RobotID(3), CB.GeomNode(nothing))
tunit = CB.TransportUnitNode(CB.ObjectID(6))
CB.add_node!(st, robot)
CB.add_node!(st, tunit)
const RID = CB.node_id(robot)     # BotID{DeliveryBot}(3)
const TID = CB.node_id(tunit)     # TemplatedID{Tuple{TransportUnitNode,ObjectID}}(6)
const ENV_ = (scene_tree = st,)
const ABSENT = CB.RobotID(9999)

@testset "🔴 C1/R34: swap_battery! 는 로봇 아닌 id 에 성공을 보고하지 않는다" begin
    saved = copy(CB.ASSET_LEDGER[])          # 🔴 전역이다. 직접 소유하고 되돌린다.
    try
        CB.reset_asset_ledger!()

        # ── 결함의 전제조건(양성 대조): 옛 문지기는 이 셋을 못 가른다 ────────────────
        @test Graphs.has_vertex(st, RID)                       # 로봇: 트리 안
        @test Graphs.has_vertex(st, TID)                       # 🔴 운반유닛도 트리 안이다
        @test !Graphs.has_vertex(st, ABSENT)                   # 없는 id: 트리 밖
        @test CB.get_node(st, RID) isa CB.RobotNode
        @test !(CB.get_node(st, TID) isa CB.RobotNode)         # 가르는 술어는 이것이다

        # ── 삼상 ────────────────────────────────────────────────────────────────
        r = CB.swap_battery!(ENV_, RID; verbose = false)
        @test r.status === :battery_swapped                    # 예 (비퇴화: 진짜 로봇은 여전히 된다)

        n = CB.swap_battery!(ENV_, ABSENT; verbose = false)
        @test n.status === :no_robot                           # 아니오

        t = CB.swap_battery!(ENV_, TID; verbose = false)
        @test t.status !== :battery_swapped                    # 🔴 거짓 성공이 사라졌다
        @test t.status === :not_a_robot                        # 구별 가능한 정직한 거절
        @test t.status !== n.status                            # "없다" 와 "로봇이 아니다" 가 다르다
        @test haskey(t, :detail) && occursin("TransportUnitNode", String(t.detail))

        # ── 도착 경로도 같이 막힌다(배송이 켜지면 `_apply_battery_swap!` 이 직접 불린다) ──
        a = CB._apply_battery_swap!(ENV_, TID; verbose = false)
        @test a.status === :not_a_robot

        # ── 🔴 장부가 안 더러워진다. 이것이 유료 런에서 실제로 새던 축이다. ────────────
        @test isempty(CB.asset_history(TID))                   # 운반유닛 앞으로 기록이 0건
        @test !isempty(CB.asset_history(RID))                  # 빈-통과 방지: 진짜 교체는 찍힌다
    finally
        empty!(CB.ASSET_LEDGER[]); append!(CB.ASSET_LEDGER[], saved)
    end
end
end # module
