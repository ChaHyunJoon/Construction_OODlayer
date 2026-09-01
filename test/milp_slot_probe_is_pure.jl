# =============================================================================
# **후보 간선 상계 프로브가 세계를 안 건드리는가.** (2026-08-31, S1/T4)
#
# 무엇을 재는가 — 그리고 무엇을 안 재는가
# ----------------------------------------
# 이 프로브는 Big-M 후보 루프의 **외곽 게이트**(`outdegree(v) < n_eligible_successors[v]`)
# 를 통과하는 **정점(vertex)** 수를 센다. 🔴 이것은 후보 (v,v2) **쌍**의 상계가 아니다 —
# 정점 하나가 여러 쌍에 기여할 수도, 하나도 기여하지 않을 수도 있어 어느 방향으로도
# 쌍의 개수를 상계짓지 못한다. 유일하게 방어 가능한 주장은 다음뿐이다:
#   · 0 이면 후보 간선이 **증명 가능하게 0** — S2 의 "재가격 단독" 경로는 죽는다.
#   · >0 이면 결론을 못 낸다. 정확한 카운트는 S2 의 몫이다.
# 🔴 상계만 재는 이유는 두 벌 방지다. 정확히 세려면 Big-M 루프의 3중 조건을 복제해야 하고,
#    안 갈리게 하려면 hot loop 를 수술해야 한다 — S1 범위 밖이다.
#
# 🔴 이 값은 **"MILP 가 돌았는가"를 주장하지 않는다.** 그건 `enact.jl` 의 센티넬
#    (`ran_milp = !(LAST_EDGE_COSTS[] === _sent)`)의 몫이고 다른 관측이다.
#
# 재는 명제 셋
#   (1) `preprocess_project_schedule` 이 정말 `sched` 만의 순수 함수다 — 두 번 불러도
#       n_eligible_successors 가 같고 스케줄 지문이 안 변한다
#   (2) 프로브 전후 env 지문(nv · ne · closed 수)이 같다
#   (3) 못 쟀으면 `nothing` 이다 — 🔴 `0` 이 아니다(삼상 규약: "후보 0" 과 "못 쟀다"를
#       같은 값으로 만들면 그 판별이 영원히 사라진다)
#
# ⚠️ 이 파일은 (3)만 잰다. (1)(2)는 진짜 `env` 가 필요하므로 여기서 재지 않는다 —
#    그 경계를 이 머리말에 적는다. 두 명제는 T5 의 실제 보드가 `[milp-probe]` 줄을 찍고
#    그 판이 정상 완주하는 것으로 확인한다. 이 파일의 초록을 "프로브가 실제 보드에서
#    작동한다"는 증거로 읽지 말 것 — n=1 실측은 T5 의 몫이다.
#
# 🔴 실측된 변이시험 결과 — 계획대로 안 됐다
# ---------------------------------------
# `candidate_slot_upper_bound` 안에는 조기 반환(`sched === nothing && return nothing`)과
# 그 뒤의 `try ... catch e; @warn ...; nothing end` 두 자리가 있다. 이 파일의 세 어서션은
# `(sched = nothing,)` 과 `nothing` 만 넣는데, 둘 다 **조기 반환**으로 빠져서 뒤의
# `catch` 블록에 한 번도 안 닿는다. 그래서 `catch; nothing end` 를 `catch; 0 end` 로
# 바꿔 실제로 돌려봐도(2026-08-31 실측) **세 어서션이 전부 그대로 PASS 한다** — (3)은
# 안 빨개진다. 즉 이 파일은 "스케줄이 아예 없다" 경로만 재고, docstring 이 존재 이유로
# 대는 "스케줄은 있는데 전처리가 던진다" 경로(진짜 `catch` 블록)는 **이 파일에서 미검증
# 이다.** 그 경로는 T5 의 실제 보드(예외를 던지는 실 스케줄이 없는 한 발화조차 안 함)로도
# 안 채워진다 — 사람이 알고 있어야 하는 남은 구멍이다.
#
# 변이시험 (실측대로 다시 적음)
#   · 조기 반환 경로: 위 세 어서션이 이미 지킨다(둘 다 nothing 을 낸다).
#   · `catch` 블록 경로(`sched` 가 있는데 전처리가 던지는 경우)는 **이 파일에서 미검증** —
#     위 박스 참조. 재려면 전처리가 던지도록 만드는 가짜 `sched` 를 따로 넣어야 한다.
#   · 프로브 안에서 `sched` 를 변경하는 줄을 넣으면 (2)가 빨개진다(단, (2)는 이 파일에서
#     측정되지 않는다 — 위 경계 참조).
#
# 실행: julia +lts --project=. test/milp_slot_probe_is_pure.jl
# =============================================================================
module MilpSlotProbeIsPure

using Test
using ConstructionBots
const CB = ConstructionBots
const REPO = normpath(joinpath(@__DIR__, ".."))
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))
include(joinpath(REPO, "tools", "monitor", "policy.jl"))

@testset "(3) 못 쟀으면 nothing 이지 0 이 아니다" begin
    # `env` 가 스케줄을 안 가진 물건이면 프로브는 던지지 않고 `nothing` 을 낸다.
    @test candidate_slot_upper_bound((sched = nothing,)) === nothing
    @test candidate_slot_upper_bound(nothing) === nothing
    # 🔴 `0` 으로 접히면 안 된다 — 그러면 "후보 0"(S2 를 죽이는 관측)과 "못 쟀다"가
    #    같은 값이 되어 판별이 사라진다.
    @test candidate_slot_upper_bound(nothing) !== 0
end

end # module
