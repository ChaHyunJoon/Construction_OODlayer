# ============================================================================
#  greedy 배정 지문 — 참고용 진단 스크립트 (더 이상 pass/fail 게이트 아님)
#
#  ⚠️ 2026-08-13 실측으로 강등됨. 이 파일은 원래 "코드변경 전 골든 해시 vs 코드변경 후 해시"를
#  서로 다른 julia 프로세스 두 개로 비교해 배선 변경이 배정을 안 바꿨음을 증명하려 했다.
#  실측 5회:
#    1 golden   (변경 전)                          c95e4c72…
#    2 repro    (변경 전, 재실행)                    c95e4c72…  = 1  (Step 3 는 이걸로 "통과"라고 판단했었음)
#    3 gate     (디스패치 배선 후)                   20d5fe75…
#    4 control  (배선을 stash 로 되돌린, 1과 바이트 동일한 코드) 5640226b…
#    5 control  (4 와 동일 코드, 재확인)              5640226b…  = 4
#  4·5 는 "코드가 1·2 와 완전히 동일"한데도 다른 해시를 낸다. 즉 **재컴파일(=julia 프로세스가
#  바뀜)이 그 자체로 배정 지문을 바꾼다** — Set/Dict 순회 순서 등 시드로 통제되지 않는 무언가가
#  프로세스마다 갈리는 것으로 보인다. 따라서 "다른 두 프로세스의 해시 비교"는 코드 변경 유무와
#  무관하게 통과할 수도 실패할 수도 있는, 구조적으로 무의미한 게이트였다(같은 프로세스 안에서는
#  결정적이다 — 1=2, 4=5. 그 성질은 여전히 유효하고 아래에서 그대로 씀).
#
#  **진짜 게이트는 `test/greedy_cost_dispatch_equivalence.jl` 이다.** 그 파일은 프로세스 간
#  비교를 하지 않고, (a) 모든 정점×dt 스프레드에 대한 공식 항등성(===)과 (b) 같은 프로세스 안에서
#  같은 pre-assignment 스케줄로 디스패치 vs 변경 전 클로저를 직접 A/B 비교한다 — 둘 다 spec §6.2
#  "GreedyFinalTimeCost 는 클로저와 바이트 단위로 같다"를 프로세스 재현성 문제 없이 직접 증명한다.
#
#  이 파일은 "그 진단을 남겨 재발 방지"용으로만 유지한다: 골든과 다시 비교하되, 다르면 **경고만**
#  출력하고 테스트를 실패시키지 않는다(위 이유로 실패가 코드 문제를 의미하지 않으므로).
#
#  사용법:
#    골든 재생성: GREEDY_GOLDEN_WRITE=1 julia +lts --project=. test/greedy_assignment_regression.jl
#    진단 실행:   julia +lts --project=. test/greedy_assignment_regression.jl
# ============================================================================

using ConstructionBots
using Test
using Random
using Graphs
using SHA
const CB = ConstructionBots

# ⚠️ 이 배너는 지워도 되는 장식이 아니다. 이 파일은 아래에서 `@testset` 을 쓰기 때문에 끝에
#    초록색 `Test Summary: ... Pass` 를 찍는다 — **게이트와 똑같이 생긴 출력**이다. 이 레포에는
#    초록 출력을 게이트 통과로 오독한 전력이 있다(CLAUDE.md 함정 목록). 그래서 실행하는 순간
#    가장 먼저 "이건 게이트가 아니다"를 말하게 한다 (2026-08-13 최종 리뷰 M-5).
println("""
################################################################################
#  ⚠️  NON-GATING DIAGNOSTIC — 이 스크립트는 pass/fail 게이트가 **아니다**.
#
#  프로세스 간 골든 해시 비교는 재컴파일만으로 지문이 바뀌는 것이 실측됐다(5회 통제 실험).
#  따라서 여기서 나오는 불일치는 코드 회귀의 증거가 아니며, 아래 `Test Summary` 의 초록색도
#  변경이 안전하다는 증거가 아니다. 두 경우 모두 아무것도 증명하지 않는다.
#
#  실제 게이트: julia +lts --project=. test/greedy_cost_dispatch_equivalence.jl
################################################################################""")

const GOLDEN_PATH = joinpath(@__DIR__, "greedy_assignment_golden.txt")
const SEED = 3
const NROB = 12

"고정 시드로 env 를 배정 직후 상태까지만 세운다(시뮬 안 함)."
function build_env()
    model = get(ENV, "GREEDY_REG_MODEL", "tractor.mpd")
    return CB.run_lego_demo(; ldraw_file = model, project_name = "greedy_reg",
        num_robots = NROB, assignment_mode = :greedy,
        save_animation = false, write_results = false, overwrite_results = true,
        return_env_before_sim = true, rng = Random.MersenneTwister(SEED))
end

"""
배정 결과의 정규 지문. 두 성분을 담는다:
  (1) 스케줄 그래프의 모든 엣지 (정렬) — 어떤 로봇이 어떤 일감에 붙었는가
  (2) 모든 정점의 tF (6자리 반올림) — 언제 끝나는가
비용식이 조금이라도 달라지면 argmin 이 갈리고 둘 중 하나가 반드시 바뀐다.
"""
function assignment_fingerprint(env)
    sched = env.sched
    io = IOBuffer()
    for e in sort(collect(Graphs.edges(sched.graph)), by = x -> (Graphs.src(x), Graphs.dst(x)))
        println(io, Graphs.src(e), "->", Graphs.dst(e))
    end
    println(io, "--tF--")
    for v in 1:Graphs.nv(sched)
        println(io, v, "=", round(CB.get_tF(sched, v), digits = 6))
    end
    body = String(take!(io))
    return bytes2hex(SHA.sha256(body)), body
end

env = build_env()
digest, body = assignment_fingerprint(env)

if get(ENV, "GREEDY_GOLDEN_WRITE", "0") == "1"
    open(GOLDEN_PATH, "w") do io
        println(io, digest)
        print(io, body)
    end
    println("[greedy-reg] GOLDEN WRITTEN: $digest -> $GOLDEN_PATH")
    println("[greedy-reg] edges+tF lines = ", count(==('\n'), body))
else
    # 더 이상 hard-fail 게이트가 아니다(위 헤더 참조 — 프로세스 간 해시 비교는 구조적으로
    # 무의미함이 실측으로 드러났다). isfile 만 진짜 @test 로 남기고, 해시 불일치는 진단
    # 정보로만 출력한다. 진짜 게이트는 test/greedy_cost_dispatch_equivalence.jl.
    @testset "greedy 배정 지문 진단 (golden 파일 존재 여부만 검증; 해시 비교는 참고용)" begin
        @test isfile(GOLDEN_PATH)
        golden_lines = readlines(GOLDEN_PATH)
        golden_digest = first(golden_lines)
        if digest != golden_digest
            # 어디가 갈렸는지 알려준다 — 해시만 다르다고 하면 디버깅이 불가능하다.
            # (참고: 2026-08-13 실측상 이 불일치는 코드 변경이 아니라 프로세스 재컴파일만으로도
            # 발생한다 — 헤더의 5회 실측 참조. 여기서 실패시키지 않는 이유.)
            golden_body = join(golden_lines[2:end], "\n") * "\n"
            gl = split(golden_body, '\n'); nl = split(body, '\n')
            for i in 1:min(length(gl), length(nl))
                gl[i] == nl[i] || (println("[greedy-reg] 첫 불일치 line $i: golden=$(gl[i]) new=$(nl[i])"); break)
            end
            println("[greedy-reg] golden lines=$(length(gl)) new lines=$(length(nl))")
            println("[greedy-reg] WARN: digest != golden_digest (참고용 — 프로세스 간 비교는 무의미함이 실측됨, 위 헤더 참조). digest=$digest golden=$golden_digest")
        else
            println("[greedy-reg] digest == golden_digest (이번 프로세스에서는 우연히 일치)")
        end
    end
end
