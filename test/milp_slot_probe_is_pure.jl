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
# 🔴 변이시험 — 실측대로 적는다 (2026-08-31 fix round 1)
# ------------------------------------------------------
# `candidate_slot_upper_bound` 안에는 두 개의 서로 다른 "nothing 을 낸다" 자리가 있다:
#   (a) 조기 반환 — `sched === nothing && return nothing`
#   (b) `catch` 블록 — `try ... catch e; @warn ...; nothing end`
# 처음 이 파일은 (3)에 `(sched = nothing,)` 과 `nothing` 만 넣었는데, 이 둘은 **모두 (a)로
# 빠져서 (b)에 한 번도 안 닿는다.** 그래서 `catch` 를 `catch; 0 end` 로 바꿔 실제로 돌려봐도
# 세 어서션이 그대로 PASS 했다 — (b)는 미검증인 채로 초록이었다. 이 회차에서
# `(sched = "not a schedule",)` 를 추가해 (b)를 실제로 덮었다. `sched` 가 있으므로 (a)를
# 피하고, `preprocess_project_schedule` 이 `String` 을 받아 `get_graph(::String)` 에서
# `MethodError` 를 던지는 것을 실측으로 확인했다(`src/graph_utils_essentials.jl:771-772` 에
# `AbstractCustomGraph`/`AbstractGraph` 특화만 있다) — 그래서 (b)로 들어간다.
#
# 아래 두 변이를 **각각 실제로 걸어서** 확인했다(둘 다 원복함):
#   · `catch e; @warn ...; nothing end` 를 `catch e; @warn ...; 0 end` 로 바꾸면 —
#     새 testset (3b)의 `=== nothing`·`!== 0` 두 어서션이 빨개진다(`0 !== 0` 은 거짓).
#     `@test_logs` 어서션은 **그대로 PASS** 한다 — `@warn` 은 안 지웠으니까(변이가 값만
#     건드렸다는 것을 이 비대칭이 보여준다).
#   · `@warn "candidate_slot_upper_bound: probe failed" exception = e` 줄을 지우면 —
#     새 testset (3b)의 `@test_logs` 어서션이 빨개진다(`Captured Logs:` 가 빈다). 값
#     어서션 둘은 그대로 PASS 한다(반환값은 안 바뀌었으니까).
# 이 비대칭이 두 손잡이(반환값의 삼상 규약 vs 경고의 존재)가 **서로 독립적으로** 지켜지고
# 있음을 보인다 — 하나가 죽어도 다른 하나가 대신 초록이 되어 숨겨주지 않는다.
#
# (1)(2)에 대해서는 이 파일에 어떤 어서션도 없으므로 "무엇을 변이하면 빨개지는가"를 이
# 파일 기준으로 주장하지 않는다 — 위 ⚠️ 경계가 그 이유(진짜 `env` 가 필요함)를 적는다.
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

@testset "(3b) catch 경로 실측 — sched 는 있는데 전처리가 던진다" begin
    # `sched` 필드가 있는 값을 넣으면 조기 반환((a))을 피해서 진짜 `try/catch`((b))에
    # 들어간다. `String` 을 넣으면 `preprocess_project_schedule` → `get_graph(::String)` 에서
    # `MethodError` 가 난다(실측 확인, `src/graph_utils_essentials.jl:771-772` 는
    # `AbstractCustomGraph`/`AbstractGraph` 특화만 있다) — 즉 (b)의 `catch` 가 반드시 돈다.
    local bad_env = (sched = "not a schedule",)
    # 삼상 규약: (b)로 들어가도 여전히 nothing 이지 0 이 아니다.
    @test candidate_slot_upper_bound(bad_env) === nothing
    @test candidate_slot_upper_bound(bad_env) !== 0
    # 🔴 경고는 손잡이다 — 없으면 "못 쟀다(genuinely unmeasurable)"와 "배선이 깨졌다"가
    #    로그에서 구별 안 된다. `run_demo.jl` 이 `Logging.Warn` 을 심으므로 `@info` 는 버려진다
    #    (그래서 `@warn` 이어야 하고, 이 어서션이 그 사실 자체를 지킨다).
    @test_logs (:warn, r"candidate_slot_upper_bound: probe failed") match_mode = :any candidate_slot_upper_bound(bad_env)
end

end # module
