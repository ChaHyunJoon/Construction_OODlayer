#!/usr/bin/env julia
# =============================================================================
# check_rollout_reset.jl — 롤아웃 경계 리셋의 **A/B 실증** (D-13R)
#
# 무엇을 보이는가: `RESPEC_HOLD[]` 는 프로세스 전역 **영구 래치**이고, 그것을 푸는 production
# 호출자가 0 개다(사용자 결정 D-13 이 그것을 설계로 확정했다). MCTS 는 한 프로세스·한
# 디렉토리에서 `G(s,a)` 를 수천 번 부르므로(§4: "트리는 한 디렉토리 안에서 굴린다"),
# **fallback 을 한 번 밟은 롤아웃이 그 뒤 전부를 오염시킨다** — 에러가 아니라 "아무것도
# 안 움직이는 세계"로.
#
# 이 스크립트는 그것을 **같은 프로세스 안에서 A/B 로** 보인다:
#   A (리셋 없음): 첫 파일이 래치를 남기고 그 뒤가 무너진다
#   B (리셋 있음): 전부 통과한다
#
#   USE_RESET=0 julia +lts --project=. tools/monitor/check_rollout_reset.jl
#   USE_RESET=1 julia +lts --project=. tools/monitor/check_rollout_reset.jl
#
# 🔴 **왜 시험이 아니라 도구인가.** 이 레포의 시험 파일은 각각 전체 env 를 짓고 RVO2 를 돌린다
#    (CLAUDE.md: 프로세스당 ~2.5 GB). 22 개 전부를 한 프로세스에 올리면 **SIGSEGV(139)** 가 난다
#    — 실측. 그건 전역 누수와 **무관한 별개의 한계**이므로, 누수를 실제로 보이는 최소
#    부분집합만 태운다. 단위 수준 계약은 `test/smdp_state_reset.jl` 이 지킨다.
#
# 실측 (2026-08-21, 병합 후 main):
#   A: 1 PASS / 3 FAIL   — respec_grammar 뒤 RESPEC_HOLD=true 로 고착
#   B: 4 PASS / 0 FAIL   — 매 파일 뒤 RESPEC_HOLD=false 로 복귀
#
# ⚠️ **간헐적 SIGSEGV(139) 는 이 리셋 탓이 아니다** — 미리 배제해 둔다(안 그러면 다음 세대가
#    다시 의심한다). 근거 둘:
#      (1) **리셋이 존재하기 전**, 22 개 전부를 한 프로세스에 올린 실행에서도 139 가 났다.
#      (2) `reset_state_globals!` 는 `:state`/`:split` 만 건드리는데, **RVO/Python 전역은 전부
#          `:replay` 또는 `:setup` 이다**(`RVO_ID_GLOBAL_MAP`·`RVO_SIM_WRAPPER`·
#          `RVO_PYTHON_MODULE` = `:replay`, 나머지 `RVO_*` = `:setup`). 즉 `deepcopy` 가
#          PyCall 객체를 만날 경로 자체가 없다. 리셋 대상에 남는 `Any` 값은
#          `HOT_SWAP_ASSETS`(NamedTuple of id/Float64)와 `STALLED_ROBOTS`(로봇 id)뿐이다.
#    B 를 2 회 반복하면 둘 다 exit=0 이다(실측).
# =============================================================================

using ConstructionBots, Test

const CB   = ConstructionBots
const REPO = normpath(joinpath(@__DIR__, "..", ".."))

CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))
CB.include(joinpath(REPO, "src", "smdp", "mdp.jl"))

const USE_RESET = get(ENV, "USE_RESET", "1") == "1"

# 누수를 실제로 보이는 최소 집합. `respec_grammar` 가 래치를 남기는 쪽이고 나머지가 피해자다.
# (전체 22 개 중 한 프로세스에서 무너지는 것은 respec_sequential_enact · respec_translate_build ·
#  smdp_derive · smdp_sojourn · smdp_tplan 다섯이다. 뒤 둘은 긴 시뮬이라 여기서는 뺐다.)
const FILES = ["respec_grammar", "respec_sequential_enact", "respec_translate_build", "smdp_tplan"]

USE_RESET && CB.capture_state_baseline!()

ok, bad = String[], String[]
for f in FILES
    try
        Base.include(Main, joinpath(REPO, "test", "$(f).jl"))
        push!(ok, f)
        println(stderr, ">>> ", rpad(f, 26), "PASS   RESPEC_HOLD=", CB.RESPEC_HOLD[])
    catch e
        push!(bad, f)
        println(stderr, ">>> ", rpad(f, 26), "FAIL   RESPEC_HOLD=", CB.RESPEC_HOLD[],
                "  :: ", first(sprint(showerror, e), 120))
    end
    USE_RESET && CB.reset_state_globals!()
end

println(stderr)
println(stderr, "### USE_RESET=$(USE_RESET):  $(length(ok)) PASS / $(length(bad)) FAIL of $(length(FILES))")

const BAD_LIST = join(bad, ", ")

if USE_RESET
    isempty(bad) || error("리셋을 켰는데도 $(length(bad)) 개가 실패한다: $(BAD_LIST) — " *
                          "리셋이 덮지 못하는 상태가 남아 있다는 뜻이다")
    println(stderr, "PASS — 롤아웃 경계 리셋이 한 프로세스 안의 격리를 회복한다")
else
    isempty(bad) && error("리셋 없이도 전부 통과했다 — 이 대조가 **항진**이다. 픽스처가 더는 " *
                          "누수를 태우지 않는다는 뜻이니 FILES 를 다시 고를 것")
    println(stderr, "EXPECTED-FAIL — 리셋 없이는 무너진다(이것이 대조군이다)")
end
